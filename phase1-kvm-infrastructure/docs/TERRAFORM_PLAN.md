# Terraform Plan for Phase 1 Infrastructure

## Resource Definitions Summary

### Networks (3 total)
```
libvirt_network.management
  - Name: kube-management
  - CIDR: 192.168.1.0/24
  - Mode: bridge (virbr1)
  - DHCP: disabled (static IPs only)

libvirt_network.storage
  - Name: kube-storage
  - CIDR: 192.168.2.0/24
  - Mode: bridge (virbr2)
  - DHCP: disabled

libvirt_network.external
  - Name: kube-external
  - CIDR: 192.168.100.0/24
  - Mode: bridge (virbr3)
  - DHCP: disabled
```

### Storage Volumes (8 total)
```
libvirt_volume.ubuntu_base
  - Image: ubuntu-noble-cloudimg
  - Size: Auto (from cloud-images.ubuntu.com)
  - Format: qcow2
  - Usage: Base for all VM root disks

libvirt_volume.root_volumes (6 total, one per VM)
  - cp-01-root:    20GB
  - w-01-root:     20GB
  - w-02-root:     20GB
  - nfs-01-root:   20GB
  - lb-01-root:    20GB
  - db-01-root:    20GB
  Total: 120GB

libvirt_volume.nfs_storage
  - Size: 50GB
  - Format: qcow2
  - Mount: /nfs/kubernetes on nfs-01
  - Usage: Persistent storage for Kubernetes

libvirt_volume.db_data
  - Size: 30GB
  - Format: qcow2
  - Mount: PostgreSQL data directory on db-01
  - Usage: Standalone DR database (separate disk from OS)
```

### Compute (6 VMs total)
```
libvirt_domain.vms["cp-01"]
  - CPU: 4 cores
  - RAM: 4096 MB
  - Networks: management, storage
  - Cloud-init: control-plane.yaml

libvirt_domain.vms["w-01"]
  - CPU: 4 cores
  - RAM: 4096 MB
  - Networks: management, storage
  - Cloud-init: worker.yaml

libvirt_domain.vms["w-02"]
  - CPU: 4 cores
  - RAM: 4096 MB
  - Networks: management, storage
  - Cloud-init: worker.yaml

libvirt_domain.vms["nfs-01"]
  - CPU: 2 cores
  - RAM: 2048 MB
  - Networks: management, storage
  - Volumes: root + 50GB storage disk
  - Cloud-init: storage.yaml

libvirt_domain.vms["lb-01"]
  - CPU: 2 cores
  - RAM: 1024 MB
  - Networks: management, external
  - Cloud-init: load-balancer.yaml

libvirt_domain.vms["db-01"]
  - CPU: 2 cores
  - RAM: 4096 MB
  - Networks: management, storage
  - Volumes: root + 30GB data disk (PostgreSQL data dir)
  - Cloud-init: database.yaml
```

### Cloud-Init ISOs (6 total)
```
libvirt_cloudinit_disk.cloudinit["cp-01"]
libvirt_cloudinit_disk.cloudinit["w-01"]
libvirt_cloudinit_disk.cloudinit["w-02"]
libvirt_cloudinit_disk.cloudinit["nfs-01"]
libvirt_cloudinit_disk.cloudinit["lb-01"]
libvirt_cloudinit_disk.cloudinit["db-01"]

Each includes:
  - Static IP configuration via netplan
  - SSH key setup
  - Package installation (containerd, kubeadm, kubelet, etc.)
  - Kernel parameter tuning
  - Service user creation
  - NTP configuration
```

## Deployment Timeline

### Estimated Duration: 10-15 minutes
- 0-1 min:   Prerequisite validation
- 1-2 min:   SSH key generation
- 2-3 min:   KVM bridge setup
- 3-4 min:   Terraform init & plan
- 4-7 min:   VM provisioning and network interface creation
- 7-10 min:  VM boot and cloud-init execution
- 10-15 min: Availability verification

## Resource Requirements

### Host System
- **CPU**: 20 cores (6 VMs × ~3 cores average)
- **RAM**: 24GB minimum (19GB for VMs + 5GB overhead)
- **Storage**: 220GB minimum (120GB root + 50GB NFS + 30GB db-01 data)
- **Network**: 1 Gbps (for cloud-init downloads)

### Total VM Resources
- **Total vCPUs**: 18 cores
- **Total RAM**: 19 GB
- **Total Storage**: 200 GB+ (120 GB root + 50 GB NFS + 30 GB db-01 data)

## Terraform Outputs

After deployment, the following outputs will be available:

```
vm_mgmt_ips = {
  "cp-01"  = "192.168.1.10"
  "w-01"   = "192.168.1.20"
  "w-02"   = "192.168.1.30"
  "nfs-01" = "192.168.1.40"
  "lb-01"  = "192.168.1.50"
  "db-01"  = "192.168.1.60"
}

vm_details = {
  "cp-01" = {
    cpus    = 4
    memory  = 4096
    mgmt_ip = "192.168.1.10"
    role    = "control-plane"
  }
  "w-01" = {
    cpus    = 4
    memory  = 4096
    mgmt_ip = "192.168.1.20"
    role    = "worker"
  }
  # ... other VMs ...
}

network_details = {
  management = {
    name    = "kube-management"
    bridge  = "virbr1"
    network = "192.168.1.0/24"
    gateway = "192.168.1.1"
  }
  storage = {
    name    = "kube-storage"
    bridge  = "virbr2"
    network = "192.168.2.0/24"
    gateway = "192.168.2.1"
  }
  external = {
    name    = "kube-external"
    bridge  = "virbr3"
    network = "192.168.100.0/24"
    gateway = "192.168.100.1"
  }
}
```

## Deployment Steps

### Step 1: Prerequisites
```bash
# Verify libvirt running
sudo systemctl status libvirtd

# Verify terraform installed
terraform version

# Add user to libvirt group
sudo usermod -aG libvirt $USER
# Re-login for changes to take effect
```

### Step 2: Generate SSH Keys
```bash
cd phase1-kvm-infrastructure
bash scripts/setup-ssh.sh
```

### Step 3: Create Terraform Variables
```bash
# This is done automatically in deploy-phase1.sh
# File created: terraform/terraform.tfvars
```

### Step 4: Deploy Infrastructure
```bash
# Option A: Full automated deployment
sudo bash scripts/deploy-phase1.sh

# Option B: Manual terraform commands
cd terraform
terraform init
terraform plan -out=tfplan
terraform apply tfplan
```

### Step 5: Verify Deployment
```bash
# List VMs
virsh list --all

# Check VM status
virsh dominfo cp-01

# Get VM IPs
virsh domifaddr cp-01

# Test SSH
bash scripts/test-ssh.sh
```

## Post-Deployment Verification

### VM Startup Checks
```bash
# SSH to control plane and verify
ssh -i .ssh/id_rsa ubuntu@192.168.1.10 "
  echo 'Checking OS version...'
  lsb_release -a
  
  echo 'Checking containerd...'
  sudo systemctl status containerd
  
  echo 'Checking kubelet...'
  sudo systemctl status kubelet
  
  echo 'Checking kernel parameters...'
  sysctl net.ipv4.ip_forward
  
  echo 'Checking network interfaces...'
  ip addr show
"
```

### Connectivity Tests
```bash
# Test inter-VM connectivity
ssh -i .ssh/id_rsa ubuntu@192.168.1.10 "ping -c 1 192.168.1.20"  # to w-01
ssh -i .ssh/id_rsa ubuntu@192.168.1.20 "ping -c 1 192.168.2.40"  # to nfs-01 storage

# Test NFS accessibility
ssh -i .ssh/id_rsa ubuntu@192.168.1.20 "
  sudo apt-get update && sudo apt-get install -y nfs-common
  sudo mount -t nfs 192.168.2.40:/nfs/kubernetes /mnt/test
  ls -la /mnt/test
  sudo umount /mnt/test
"
```

## Rollback/Teardown

### Full Teardown
```bash
sudo bash scripts/cleanup-phase1.sh
```

### Partial Rollback (Terraform)
```bash
cd terraform
terraform destroy -target libvirt_domain.vms["w-01"]  # Remove specific VM
terraform destroy  # Remove everything
```

## Customization Options

### Change VM Sizes
Edit `terraform/main.tf` locals section:
```hcl
"cp-01" = {
  cpus = 8        # Increase from 4
  memory = 8192   # Increase from 4096
  # ...
}
```

### Change Network CIDRs
Edit `terraform/networks.tf`:
```hcl
addresses = ["192.168.50.0/24"]  # Change from 192.168.1.0/24
```

### Add Additional Workers
Edit `terraform/main.tf` to add more entries in `vm_configs` map.

## Troubleshooting the Terraform Plan

### Validation Errors
```bash
terraform validate
# Fix any syntax errors reported
```

### Plan Differences
```bash
terraform plan -detailed-exitcode
# Exit code 0: No changes
# Exit code 1: Error occurred
# Exit code 2: Changes pending
```

### State Issues
```bash
# Check state
terraform state list
terraform state show libvirt_domain.vms["cp-01"]

# Import existing resources
terraform import libvirt_domain.vms["cp-01"] cp-01
```
