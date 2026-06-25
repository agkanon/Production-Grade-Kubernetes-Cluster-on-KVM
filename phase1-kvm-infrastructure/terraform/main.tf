terraform {
  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "~> 0.8.1"
    }
  }
  required_version = ">= 1.9"
}

provider "libvirt" {
  uri = var.libvirt_uri
}

# Define local variables for common configurations
locals {
  base_image_url  = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
  base_image_size = 10 * 1024 * 1024 * 1024 # 10GB

  # Maps each VM name to its cloud-init filename (used in vms.tf templatefile call)
  cloud_init_templates = {
    "cp-01"  = "control-plane.yaml"
    "w-01"   = "worker.yaml"
    "w-02"   = "worker.yaml"
    "nfs-01" = "storage.yaml"
    "lb-01"  = "load-balancer.yaml"
    "db-01"  = "database.yaml"
  }

  vm_configs = {
    "cp-01" = {
      role       = "control-plane"
      cpus       = 4
      memory     = 4096
      root_disk  = 20 * 1024 * 1024 * 1024 # 20 GB
      mgmt_ip    = "192.168.1.10"
      storage_ip = "192.168.2.10"
    }
    "w-01" = {
      role       = "worker"
      cpus       = 4
      memory     = 4096
      root_disk  = 20 * 1024 * 1024 * 1024
      mgmt_ip    = "192.168.1.20"
      storage_ip = "192.168.2.20"
    }
    "w-02" = {
      role       = "worker"
      cpus       = 4
      memory     = 4096
      root_disk  = 20 * 1024 * 1024 * 1024
      mgmt_ip    = "192.168.1.30"
      storage_ip = "192.168.2.30"
    }
    "nfs-01" = {
      role         = "storage"
      cpus         = 2
      memory       = 2048
      root_disk    = 20 * 1024 * 1024 * 1024
      storage_disk = 50 * 1024 * 1024 * 1024 # 50 GB NFS export volume
      mgmt_ip      = "192.168.1.40"
      storage_ip   = "192.168.2.40"
    }
    "lb-01" = {
        role        = "load-balancer"
        cpus        = 2
        memory      = 1024
        root_disk   = 20 * 1024 * 1024 * 1024
      mgmt_ip     = "192.168.1.50"
      external_ip = "192.168.100.10"
    }
    # Dedicated PostgreSQL VM — isolates database I/O from Kubernetes nodes
    # and Kubernetes storage traffic, reducing contention on both networks.
    "db-01" = {
      role      = "database"
      cpus      = 2
      memory    = 4096 # PostgreSQL benefits from more RAM for shared_buffers
      root_disk = 20 * 1024 * 1024 * 1024
      data_disk = 30 * 1024 * 1024 * 1024 # 30 GB separate disk for PG data dir
      mgmt_ip   = "192.168.1.60"
      storage_ip = "192.168.2.60"
    }
  }
}

