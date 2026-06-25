#!/bin/bash
set -euo pipefail

# Cleanup Phase 1 Infrastructure
# This script tears down all KVM resources created by Phase 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

main() {
    log_warn "This will destroy all Phase 1 infrastructure. Press Ctrl+C to cancel."
    sleep 5
    
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    # Destroy Terraform resources
    log_info "Destroying Terraform resources..."
    cd "${PROJECT_ROOT}/terraform"
    terraform destroy -auto-approve || log_warn "Terraform destroy had issues"

    # Force-remove any domains that exist outside Terraform state (partial apply remnants)
    log_info "Cleaning up any remaining libvirt domains..."
    for vm in cp-01 w-01 w-02 nfs-01 lb-01 db-01; do
        if virsh dominfo "$vm" &>/dev/null; then
            log_warn "Domain '$vm' still exists — force-removing..."
            virsh destroy "$vm" 2>/dev/null || true
            virsh undefine "$vm" 2>/dev/null || true
        fi
    done

    # Clean up bridges
    log_info "Cleaning up bridges..."
    for bridge in virbr1 virbr2 virbr3; do
        if ip link show "$bridge" &> /dev/null; then
            ip link set "$bridge" down
            ip link del "$bridge"
            log_info "Removed bridge $bridge"
        fi
    done

    # Remove iptables rules for custom bridges
    log_info "Cleaning up iptables rules..."
    for bridge in virbr1 virbr2 virbr3; do
        iptables -D FORWARD -i "$bridge" -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -o "$bridge" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true
        iptables -t nat -D POSTROUTING -s 192.168.1.0/24 ! -o "$bridge" -j MASQUERADE 2>/dev/null || true
        iptables -t nat -D POSTROUTING -s 192.168.2.0/24 ! -o "$bridge" -j MASQUERADE 2>/dev/null || true
        iptables -t nat -D POSTROUTING -s 192.168.100.0/24 ! -o "$bridge" -j MASQUERADE 2>/dev/null || true
    done
    
    log_info "Cleanup complete"
}

main "$@"
