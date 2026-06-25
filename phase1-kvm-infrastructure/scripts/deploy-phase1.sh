#!/bin/bash
set -euo pipefail

# Phase 1 KVM Infrastructure Setup Script
# This script automates the deployment of Kubernetes infrastructure on KVM

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."
    
    # Check if running as root
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Install genisoimage if missing (provides mkisofs, required by libvirt provider)
    if ! command -v mkisofs &> /dev/null && ! command -v genisoimage &> /dev/null; then
        log_info "Installing genisoimage..."
        apt-get install -y genisoimage
    fi

    # Check for required tools
    local required_tools=("virsh" "terraform" "ssh-keygen" "qemu-system-x86_64")
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" &> /dev/null; then
            log_error "Required tool not found: $tool"
            exit 1
        fi
    done
    
    log_info "All prerequisites met"
}

# Setup SSH keys
setup_ssh_keys() {
    log_info "Setting up SSH keys..."
    
    local key_dir="${PROJECT_ROOT}/.ssh"
    local private_key="${key_dir}/id_rsa"
    local public_key="${key_dir}/id_rsa.pub"
    
    if [[ -f "$private_key" ]]; then
        log_warn "SSH keys already exist at $private_key"
        return 0
    fi
    
    mkdir -p "$key_dir"
    ssh-keygen -t ed25519 -f "$private_key" -N "" -C "kubernetes@agk"
    chmod 600 "$private_key"
    chmod 644 "$public_key"
    
    log_info "SSH keys created: $public_key"
}

# Ensure KVM acceleration is available
setup_kvm_acceleration() {
    log_info "Checking KVM acceleration..."

    if [[ -e /dev/kvm ]]; then
        log_info "KVM acceleration already active (/dev/kvm present)"
        chmod 666 /dev/kvm
        return 0
    fi

    # On AWS Nitro, vmx/svm are hidden from /proc/cpuinfo but the generic
    # 'kvm' module still loads and creates /dev/kvm. Try it first.
    log_info "Attempting to load kvm module (EC2 Nitro / generic)..."
    modprobe kvm 2>/dev/null || true

    # Then load the vendor-specific module if CPU flags are visible
    if grep -q vmx /proc/cpuinfo; then
        log_info "Intel CPU detected, loading kvm_intel..."
        modprobe kvm_intel 2>/dev/null || true
    elif grep -q svm /proc/cpuinfo; then
        log_info "AMD CPU detected, loading kvm_amd..."
        modprobe kvm_amd 2>/dev/null || true
    else
        log_warn "vmx/svm not visible in /proc/cpuinfo - attempting to load generic kvm module"
    fi

    if [[ ! -e /dev/kvm ]]; then
        log_error "/dev/kvm not present after loading KVM modules."
        log_error "type with nested virtualisation support. Check: dmesg | grep -i kvm"
        exit 1
    fi

    chmod 666 /dev/kvm
    log_info "KVM acceleration enabled"
}

# Configure QEMU to run as root and disable AppArmor/SELinux confinement.
# By default QEMU runs as libvirt-qemu and AppArmor restricts file access,
# both of which cause Permission denied on images downloaded by root.
# Appending to qemu.conf is safer than sed-patching commented lines whose
# exact format varies across distro versions.
configure_qemu_permissions() {
    log_info "Configuring QEMU permissions in /etc/libvirt/qemu.conf..."

    local conf="/etc/libvirt/qemu.conf"
    local changed=0

    if ! grep -qE '^user\s*=\s*"root"' "$conf"; then
        echo 'user = "root"' >> "$conf"
        changed=1
    fi
    if ! grep -qE '^group\s*=\s*"root"' "$conf"; then
        echo 'group = "root"' >> "$conf"
        changed=1
    fi
    # Disable AppArmor/SELinux for QEMU — prevents Permission denied even when
    # running as root on Ubuntu systems where AppArmor confines by file path.
    if ! grep -qE '^security_driver\s*=\s*"none"' "$conf"; then
        echo 'security_driver = "none"' >> "$conf"
        changed=1
    fi

    if [[ $changed -eq 1 ]]; then
        log_info "Restarting libvirtd to apply QEMU permission changes..."
        systemctl restart libvirtd
        sleep 2
    fi

    # Ensure the base image (downloaded by root) is readable by any QEMU user
    local images_dir="/var/lib/libvirt/images"
    if [[ -d "$images_dir" ]]; then
        chmod o+x "$images_dir"
        find "$images_dir" -maxdepth 1 -type f -name "*.img" -o -name "*.qcow2" \
            | xargs -r chmod o+r
    fi
}

# Create KVM networks (manual setup as Terraform may not handle this)
setup_kvm_networks() {
    log_info "Setting up KVM networks..."
    
    # Create bridges if they don't exist
    local bridges=("virbr1" "virbr2" "virbr3")
    declare -A BRIDGE_CIDR=([virbr1]="192.168.1.1/24" [virbr2]="192.168.2.1/24" [virbr3]="192.168.100.1/24")
    declare -A BRIDGE_NET=([virbr1]="192.168.1.0/24" [virbr2]="192.168.2.0/24" [virbr3]="192.168.100.0/24")

    for bridge in "${bridges[@]}"; do
        if ip link show "$bridge" &> /dev/null; then
            log_warn "Bridge $bridge already exists"
        else
            log_info "Creating bridge $bridge..."
            ip link add "$bridge" type bridge
            ip addr add "${BRIDGE_CIDR[$bridge]}" dev "$bridge"
            ip link set "$bridge" up
        fi
    done

    # Add iptables rules for NAT and forwarding on the custom bridges
    # so VMs can reach the internet through the host
    log_info "Adding iptables rules for bridge NAT/forwarding..."
    for bridge in "${bridges[@]}"; do
        local net="${BRIDGE_NET[$bridge]}"
        # Allow forwarding from bridge to external interfaces
        iptables -A FORWARD -i "$bridge" -j ACCEPT 2>/dev/null || true
        iptables -A FORWARD -o "$bridge" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
        # Masquerade traffic from bridge networks to the outside
        iptables -t nat -A POSTROUTING -s "$net" ! -o "$bridge" -j MASQUERADE 2>/dev/null || true
    done
    # Ensure ip_forward is enabled
    echo 1 > /proc/sys/net/ipv4/ip_forward
}

# Ensure the default libvirt storage pool exists
setup_storage_pool() {
    log_info "Setting up libvirt storage pool..."

    if virsh pool-info default &> /dev/null; then
        log_warn "Storage pool 'default' already exists"
        virsh pool-start default 2>/dev/null || true
    else
        log_info "Creating storage pool 'default'..."
        virsh pool-define-as default dir --target /var/lib/libvirt/images
        virsh pool-build default
        virsh pool-start default
        virsh pool-autostart default
    fi
}

# Remove any libvirt domains that exist outside Terraform state.
# This happens when a previous apply failed mid-way: libvirt defined the domain
# but Terraform never recorded it, so the next apply collides.
cleanup_orphaned_domains() {
    log_info "Checking for orphaned libvirt domains..."
    local vms=("cp-01" "w-01" "w-02" "nfs-01" "lb-01" "db-01")
    for vm in "${vms[@]}"; do
        if virsh dominfo "$vm" &>/dev/null; then
            log_warn "Orphaned domain '$vm' found — removing before apply..."
            virsh destroy "$vm" 2>/dev/null || true
            virsh undefine "$vm" 2>/dev/null || true
        fi
    done
}

# Initialize Terraform
init_terraform() {
    log_info "Initializing Terraform..."
    
    cd "${PROJECT_ROOT}/terraform"
    
    # Create terraform.tfvars
    local ssh_pub_key=$(cat "${PROJECT_ROOT}/.ssh/id_rsa.pub")
    local ssh_priv_key=$(cat "${PROJECT_ROOT}/.ssh/id_rsa" | base64 -w0)
    
    cat > terraform.tfvars <<EOF
libvirt_uri  = "qemu:///system"
libvirt_pool = "default"
bridge_mgmt  = "virbr1"
bridge_storage = "virbr2"
bridge_external = "virbr3"
ssh_public_key = "${ssh_pub_key}"
ssh_private_key = "${ssh_priv_key}"
EOF
    
    terraform init
    log_info "Terraform initialized"
}

# Deploy infrastructure with Terraform
deploy_infrastructure() {
    log_info "Deploying infrastructure with Terraform..."
    
    cd "${PROJECT_ROOT}/terraform"
    terraform validate || { log_error "Terraform validation failed"; exit 1; }
    terraform plan -out=tfplan
    terraform apply tfplan
    
    log_info "Infrastructure deployed successfully"
    
    # Save outputs
    terraform output -json > "${PROJECT_ROOT}/.deployment_output.json"
}

# Wait for VMs to be ready
wait_for_vms() {
    log_info "Waiting for VMs to boot and cloud-init to complete..."
    
    local max_retries=60
    local retry_count=0
    
    while [[ $retry_count -lt $max_retries ]]; do
        if virsh list --all | grep -q "running"; then
            log_info "VMs are running"
            sleep 30  # Wait for cloud-init
            return 0
        fi
        
        log_info "Waiting for VMs to start... ($((retry_count+1))/$max_retries)"
        sleep 10
        ((retry_count++))
    done
    
    log_error "Timeout waiting for VMs to start"
    return 1
}

# Verify infrastructure
verify_infrastructure() {
    log_info "Verifying infrastructure..."
    
    # List all VMs
    log_info "VMs:"
    virsh list --all
    
    # List networks
    log_info "Networks:"
    virsh net-list --all
    
    # Get VM IPs
    log_info "VM IP Addresses:"
    for vm in cp-01 w-01 w-02 nfs-01 lb-01 db-01; do
        local ip=$(virsh domifaddr "$vm" 2>/dev/null | grep 'ipv4' | awk '{print $4}' | cut -d'/' -f1)
        if [[ -n "$ip" ]]; then
            echo "  $vm: $ip"
        fi
    done
}

# Main execution
main() {
    log_info "Starting Phase 1: KVM Infrastructure Setup"
    
    check_prerequisites
    setup_kvm_acceleration
    configure_qemu_permissions
    setup_ssh_keys
    setup_kvm_networks
    setup_storage_pool
    cleanup_orphaned_domains
    init_terraform
    deploy_infrastructure
    wait_for_vms
    verify_infrastructure
    
    log_info "Phase 1 deployment complete!"
    log_info "Next steps: Run 'Phase 2' for Kubernetes cluster setup"
}

main "$@"
