# Phase 1: KVM Infrastructure Setup - README

## Overview

This directory contains Infrastructure-as-Code (IaC) for provisioning a production-grade Kubernetes cluster on KVM virtual machines. Phase 1 focuses on infrastructure foundation: VMs, networking, and system configuration.

**Status**: Automated via Terraform, deployable with single script.

## Infrastructure Topology

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                          KVM Hypervisor  (physical host)                        │
│                                                                                 │
│   Docker (image builds) · Terraform · GitHub Actions Self-Hosted Runner        │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │              Management Network  192.168.1.0/24  (kube-management)      │   │
│  │                                                                         │   │
│  │  .10 cp-01 ──────────────────────────┐                                 │   │
│  │  Control Plane (4 CPU, 4 GB)         │ kubeadm cluster                 │   │
│  │  etcd · API :6443 · Scheduler        │                                 │   │
│  │                                      │                                 │   │
│  │  .20 w-01 ──────────┐               │                                 │   │
│  │  Worker 1 (4 CPU, 4 GB)             ├── Cilium eBPF pod network        │   │
│  │                      │               │   10.244.0.0/16                 │   │
│  │  .30 w-02 ──────────┘               │   Services 10.96.0.0/12         │   │
│  │  Worker 2 (4 CPU, 4 GB)             │                                 │   │
│  │                                      │   Kong NodePort :30080          │   │
│  │  .40 nfs-01 ◄────────── NFS ────────┘   on w-01 and w-02             │   │
│  │  NFS Server (2 CPU, 2 GB, 50 GB disk)                                 │   │
│  │  /nfs/kubernetes ← nfs-subdir-provisioner PVCs                        │   │
│  │                                                                         │   │
│  │  .50 lb-01 ◄──────── HAProxy :80 ──────► Kong :30080                  │   │
│  │  Load Balancer (2 CPU, 1 GB)                                           │   │
│  │                                                                         │   │
│  │  .60 db-01                                                              │   │
│  │  PostgreSQL 17 Standalone (2 CPU, 4 GB, 20 GB root + 30 GB data disk)  │   │
│  │  Failover target for Phase 6 DB restore runbook                        │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │              Storage Network  192.168.2.0/24  (kube-storage)           │   │
│  │  cp-01 .10 · w-01 .20 · w-02 .30 · nfs-01 .40 · db-01 .60            │   │
│  │  NFS data traffic is isolated here — never crosses management NIC      │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
│                                                                                 │
│  ┌─────────────────────────────────────────────────────────────────────────┐   │
│  │              External Network  192.168.100.0/24  (kube-external)       │   │
│  │  lb-01 .10  ←── User/Browser traffic enters here on port 80            │   │
│  └─────────────────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────────────────┘

Traffic path: User → lb-01:80 → HAProxy → Kong NodePort :30080 (w-01/w-02)
              → /api → backend-service:3000 → postgres StatefulSet (PVC on nfs-01)
              → /    → frontend-service:80  → nginx (React SPA)
```

---

## Prerequisites

### Host System Requirements
- **Hypervisor**: KVM/QEMU on Linux (tested on Ubuntu 24.04 LTS)
- **CPU**: 8+ cores recommended (minimum 20 cores for all 6 VMs running)
- **RAM**: 16GB minimum (recommended 24GB+)
- **Storage**: 200GB free disk space for VM volumes
- **Network**: Host with internet access for package downloads

### Required Tools
- `terraform` >= 1.0
- `libvirt` / `virt-manager`
- `virsh` CLI
- `ssh-keygen`
- `qemu-system-x86_64`
- `docker` >= 24 (for building application images in Phase 3/7)
- `git`

### Installation (Ubuntu 24.04)
```bash
# Install KVM and Terraform dependencies
sudo apt-get update

sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients bridge-utils virtinst openssh-client
sudo systemctl enable --now libvirtd

# Add your user to the kvm group
sudo usermod -aG kvm,libvirt $USER  

# Start libvirtd
sudo systemctl enable libvirtd
sudo systemctl start libvirtd

# Add current user to libvirt group
sudo usermod -aG libvirt $USER
sudo apt update && sudo apt install -y gnupg software-properties-common curl

#  Add HashiCorp's GPG key
curl -fsSL https://apt.releases.hashicorp.com/gpg | \
  gpg --dearmor | \
  sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg > /dev/null

#  Add the HashiCorp apt repository
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
  https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
  sudo tee /etc/apt/sources.list.d/hashicorp.list

#  Update and install Terraform
sudo apt update && sudo apt install -y terraform

#  Verify installation
terraform version


# Install Docker (used by the CI/CD pipeline to build container images)
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker $USER

# Re-login for both group memberships to take effect
newgrp docker
```

### GitHub Actions Self-Hosted Runner

The Phase 7 CI/CD pipeline runs on a self-hosted GitHub Actions runner installed
on this hypervisor. The runner must be installed **before** pushing code to GitHub
so it is available when the first workflow is triggered.

GitHub's cloud-hosted runners cannot reach `192.168.1.x` (private KVM network).
The runner process on the hypervisor has direct layer-2 access to all cluster nodes.

```bash
# Create the runner directory
mkdir -p ~/actions-runner && cd ~/actions-runner

# Download the runner binary
# (replace RUNNER_VERSION with the current release shown in GitHub UI)
RUNNER_VERSION=2.316.0
curl -o actions-runner-linux-x64.tar.gz -L \
  "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
tar xzf ./actions-runner-linux-x64.tar.gz

# Register with your GitHub repository
# (copy the --token value from: repo → Settings → Actions → Runners → New runner)
./config.sh \
  --url https://github.com/<YOUR_USERNAME>/bmi-health-tracker \
  --token <TOKEN_FROM_GITHUB_UI> \
  --name hypervisor-runner \
  --labels self-hosted,linux,kvm \
  --unattended

# Install as a systemd service so it survives reboots
sudo ./svc.sh install
sudo ./svc.sh start

# Verify: runner should show Idle (green) in GitHub → Settings → Actions → Runners
sudo ./svc.sh status
```

## Quick Start

### 1. Generate SSH Keys
```bash
cd phase1-kvm-infrastructure
bash scripts/setup-ssh.sh
```

### 2. Deploy Infrastructure
```bash
cd phase1-kvm-infrastructure
sudo bash scripts/deploy-phase1.sh
```

This script will:
- Validate prerequisites
- Generate SSH keys
- Set up KVM bridges
- Initialize Terraform
- Deploy 6 VMs with cloud-init configuration
- Verify deployment

**Expected duration**: 10-15 minutes

### 3. Verify Deployment
```bash
# List running VMs
cat >> ~/.bashrc << 'EOF'

virsh-list() {
  echo " Id   Name       State       IP Address"
  echo "----------------------------------------------"
  virsh list --all | awk 'NR>2 && $2!=""' | while read id name state; do
    mac=$(virsh domiflist $name 2>/dev/null | awk 'NR>2 && $1!="" {print $5}' | head -1)
    ip=$(ip neigh show | grep -i "$mac" | awk '{print $1}')
    printf " %-4s %-10s %-12s %s\n" "$id" "$name" "$state" "${ip:-N/A}"
  done
}
EOF
source ~/.bashrc

virsh-list


# Check VM IPs
virsh domifaddr cp-01
virsh domifaddr w-01
virsh domifaddr w-02
virsh domifaddr nfs-01
virsh domifaddr lb-01

# Test SSH connectivity
bash scripts/test-ssh.sh
```

### 4. Access VMs
```bash
# Permission given in .ssh folder
sudo chown -R ubuntu:ubuntu .ssh/
# SSH to control plane
ssh -i .ssh/id_rsa ubuntu@192.168.1.10

# SSH to worker 1
ssh -i .ssh/id_rsa ubuntu@192.168.1.20

# SSH to NFS server
ssh -i .ssh/id_rsa ubuntu@192.168.1.40
```

## Project Structure

```
phase1-kvm-infrastructure/
├── terraform/                    # Infrastructure as Code
│   ├── main.tf                  # Provider & local variables
│   ├── networks.tf              # KVM network definitions
│   ├── vms.tf                   # VM definitions
│   ├── variables.tf             # Input variables
│   ├── outputs.tf               # Output values
│   └── terraform.tfvars         # Generated on deployment
│
├── cloud-init/                  # VM initialization configs
│   ├── control-plane.yaml       # Control plane node setup
│   ├── worker.yaml              # Worker node setup
│   ├── storage.yaml             # NFS server setup
│   ├── load-balancer.yaml       # HAProxy LB setup
│   └── database.yaml            # db-01 PostgreSQL standalone node
│
├── scripts/                     # Deployment & management scripts
│   ├── deploy-phase1.sh         # Main deployment script
│   ├── cleanup-phase1.sh        # Teardown & cleanup
│   ├── setup-ssh.sh             # SSH key generation
│   └── test-ssh.sh              # Connectivity testing
│
├── docs/                        # Documentation
│   ├── NETWORK_TOPOLOGY.md      # Network diagram & config
│   ├── DESIGN_DECISIONS.md      # Rationale for all choices
│   └── README.md                # This file
│
└── .ssh/                        # Generated SSH keys (gitignored)
    ├── id_rsa                   # Private key
    └── id_rsa.pub               # Public key
```

## Network Configuration

### Three Isolated Networks

| Network | CIDR | Gateway | Purpose |
|---------|------|---------|---------|
| Management | 192.168.1.0/24 | 192.168.1.1 | Kubernetes API, SSH, control plane |
| Storage | 192.168.2.0/24 | 192.168.2.1 | NFS traffic, storage I/O |
| External | 192.168.100.0/24 | 192.168.100.1 | Ingress traffic to load balancer |

### VM Allocation

| VM Name | Role | CPU | RAM | Root Disk | Data Disk | Mgmt IP | Storage IP | External IP |
|---------|------|-----|-----|-----------|-----------|---------|------------|-------------|
| cp-01 | Control Plane | 4 | 4GB | 20GB | — | 192.168.1.10 | 192.168.2.10 | — |
| w-01 | Worker 1 | 4 | 4GB | 20GB | — | 192.168.1.20 | 192.168.2.20 | — |
| w-02 | Worker 2 | 4 | 4GB | 20GB | — | 192.168.1.30 | 192.168.2.30 | — |
| nfs-01 | NFS Storage | 2 | 2GB | 20GB | 50GB | 192.168.1.40 | 192.168.2.40 | — |
| lb-01 | Load Balancer | 2 | 1GB | 20GB | — | 192.168.1.50 | — | 192.168.100.10 |
| db-01 | Database (standalone) | 2 | 4GB | 20GB | 30GB | 192.168.1.60 | 192.168.2.60 | — |

**Total Resources**: 18 CPU cores, 19GB RAM, 320GB+ storage  
`db-01` provides a standalone PostgreSQL 17 fallback used during Kubernetes DB failover (Runbook 6.5).

## System Configuration

### Kernel Parameters
All VMs have Kubernetes-optimized kernel parameters:
- Bridge traffic through iptables
- IPv4 forwarding enabled
- High inotify watch limits
- Large file descriptor limits

### Container Runtime
- **Runtime**: containerd (CNCF standard)
- **CRI**: Kubernetes CRI plugin enabled
- **Cgroup Driver**: systemd (for resource management)

### SSH Configuration
- **Keys**: Ed25519 (modern, secure)
- **Authentication**: Key-based only, passwords disabled
- **Root**: Disabled, use `sudo` for privilege escalation

### Time Synchronization
- **NTP**: chrony enabled on all nodes
- **Timezone**: UTC

## Common Operations

### View VM Status
```bash
virsh list --all
virsh dominfo cp-01
virsh domstats cp-01 --cpu-total
```

### Connect to VM Console
```bash
# VNC console (graphical)
virt-viewer cp-01

# Serial console
virsh console cp-01
```

### Modify VM Resources
```bash
# Increase control plane RAM (while powered off)
virsh destroy cp-01
virsh edit cp-01  # Edit memory allocation
virsh start cp-01
```

### View Cloud-init Logs
```bash
ssh ubuntu@192.168.1.10 "tail -100 /var/log/cloud-init-output.log"
```

### Rebuild a Single VM
```bash
# Remove old VM
virsh destroy w-01
virsh undefine w-01
virsh vol-delete w-01-root --pool default

# Redeploy
cd terraform
terraform taint libvirt_domain.vms["w-01"]
terraform apply -auto-approve
```

## Troubleshooting

### VM Won't Start
```bash
# Check error messages
virsh start cp-01
virsh dominfo cp-01

# Check system logs
journalctl -u libvirtd -n 50

# Validate Terraform configs
cd terraform
terraform validate
terraform plan
```

### SSH Connection Refused
```bash
# Verify VM is running
virsh list --all | grep cp-01

# Check if cloud-init completed
ssh ubuntu@192.168.1.10 "sudo cloud-init status"

# Check network connectivity
ssh ubuntu@192.168.1.10 "ip addr show"

# Check SSH service
ssh ubuntu@192.168.1.10 "sudo systemctl status ssh"
```

### Cloud-init Didn't Complete
```bash
# Check cloud-init status
ssh ubuntu@192.168.1.10 "sudo cloud-init status"

# View cloud-init logs
ssh ubuntu@192.168.1.10 "sudo tail -200 /var/log/cloud-init-output.log"

# Re-run cloud-init (careful!)
ssh ubuntu@192.168.1.10 "sudo cloud-init clean --all && sudo cloud-init init"
```

### NFS Storage Not Available
```bash
# Check NFS server status
ssh ubuntu@192.168.1.40 "sudo systemctl status nfs-server"
ssh ubuntu@192.168.1.40 "sudo exportfs -v"

# Check disk space
ssh ubuntu@192.168.1.40 "df -h /nfs/kubernetes"

# Test NFS mount from worker
ssh ubuntu@192.168.1.20 "sudo mount -t nfs 192.168.2.40:/nfs/kubernetes /mnt/test"
```

## Cleanup & Teardown

### Remove All Infrastructure
```bash
sudo bash scripts/cleanup-phase1.sh
```

This will:
- Destroy all VMs
- Delete volumes
- Remove Terraform state
- Tear down KVM bridges

**Warning**: This is destructive and cannot be undone.

### Partial Cleanup
```bash
# Remove specific VM
virsh destroy w-01
virsh undefine w-01
virsh vol-delete w-01-root --pool default

# Remove specific volume
virsh vol-delete nfs-01-storage --pool default

# Destroy network
virsh net-destroy kube-management
```

## Security Considerations

### Current Posture
- ✓ SSH key-based authentication
- ✓ Password authentication disabled
- ✓ Root account disabled
- ✓ Network isolation between traffic types

### To Enhance (Phase 2+)
- Host-based firewall (UFW)
- Pod Security Policies
- Network policies (block pod-to-pod by default)
- Secret encryption at rest
- Audit logging
- Container image scanning

## Performance Tuning

### Network Performance
```bash
# Check network performance between nodes
ssh ubuntu@192.168.1.10 "iperf3 -s" &
ssh ubuntu@192.168.1.20 "iperf3 -c 192.168.1.10"

# Monitor network usage
ssh ubuntu@192.168.1.10 "iftop -i eth0"
```

### Storage Performance
```bash
# Benchmark NFS throughput
ssh ubuntu@192.168.1.40 "fio --name=test --ioengine=libaio --size=1g --runtime=60s"
```

### VM Performance
```bash
# Check CPU/Memory usage
virsh domstats --cpu-total cp-01
virsh dominfo cp-01 | grep memory
```

## Monitoring & Observability

### Phase 1 Monitoring
- Manual: `virsh` commands for VM status
- SSH tests for connectivity
- Cloud-init logs for startup issues

### Phase 2/4 Planned
- Prometheus metrics
- Loki centralized logging
- Grafana dashboards
- Alert management

## Next Steps

After Phase 1 deployment is verified:

1. **Phase 2**: Deploy Kubernetes cluster
   - Initialize control plane with `kubeadm`
   - Join worker nodes
   - Install Cilium CNI
   - Set up NFS storage provisioning

2. **Phase 3**: Deploy application
   - Build container images on the hypervisor (`docker build`)
   - Transfer images to cluster nodes (`docker save | scp | ctr import`)
   - Apply Kubernetes manifests (namespace → StatefulSet → Deployments → Kong)

3. **Phase 4**: Monitoring & logging
   - Prometheus + Grafana (metrics, alerting)
   - Loki + Promtail (centralized log aggregation)
   - pg_dump CronJob (daily database backup to NFS)

4. **Phase 5**: Security hardening
   - Pod Security Admission (`restricted` profile on production namespace)
   - Dedicated ServiceAccounts, RBAC, zero-trust NetworkPolicies

5. **Phase 6**: Operations runbooks
   - Node add/remove, rolling update, DB restore, failover to db-01

6. **Phase 7**: CI/CD pipeline
   - GitHub Actions self-hosted runner (already installed on this hypervisor)
   - Automated build → transfer → deploy on every push to `main`

See [../../README.md](../../README.md) for overall project structure.

## References

- **Terraform libvirt provider**: https://github.com/dmacvicar/terraform-provider-libvirt
- **Kubernetes documentation**: https://kubernetes.io/docs/
- **cloud-init docs**: https://cloud-init.io/
- **containerd docs**: https://containerd.io/
- **Network topology best practices**: https://kubernetes.io/docs/concepts/cluster-administration/networking/

## Support

For issues or questions:
1. Check `/docs/DESIGN_DECISIONS.md` for rationale
2. Review cloud-init logs on VMs
3. Consult Terraform state and logs
4. Check libvirtd systemd logs: `journalctl -u libvirtd -n 100`

---

**Project**: agk Technical Assessment - Production-Grade Kubernetes on KVM  
**Phase**: 1 - Infrastructure Setup  
**Status**: Production Ready
