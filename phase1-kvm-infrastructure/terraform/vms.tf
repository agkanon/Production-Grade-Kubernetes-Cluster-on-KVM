# Download and cache base image
resource "libvirt_volume" "ubuntu_base" {
  name   = "ubuntu-noble-base"
  pool   = var.libvirt_pool
  source = local.base_image_url
  format = "qcow2"
}

# Root volumes for every VM (cloned from base image)
resource "libvirt_volume" "root_volumes" {
  for_each = local.vm_configs

  name           = "${each.key}-root"
  pool           = var.libvirt_pool
  base_volume_id = libvirt_volume.ubuntu_base.id
  size           = each.value.root_disk
  format         = "qcow2"
}

# Dedicated NFS export volume (nfs-01 only)
resource "libvirt_volume" "nfs_storage" {
  name   = "nfs-01-storage"
  pool   = var.libvirt_pool
  size   = local.vm_configs["nfs-01"].storage_disk
  format = "qcow2"
}

# Dedicated PostgreSQL data volume (db-01 only)
# Separate disk isolates DB I/O and makes snapshot-based backups straightforward.
resource "libvirt_volume" "db_data" {
  name   = "db-01-data"
  pool   = var.libvirt_pool
  size   = local.vm_configs["db-01"].data_disk
  format = "qcow2"
}

# Cloud-init ISO per VM
resource "libvirt_cloudinit_disk" "cloudinit" {
  for_each = local.vm_configs

  name = "${each.key}-cloudinit"
  pool = var.libvirt_pool

  user_data = templatefile(
    "${path.module}/../cloud-init/${local.cloud_init_templates[each.key]}",
    {
      hostname         = each.key
      mgmt_ip          = each.value.mgmt_ip
      storage_ip       = lookup(each.value, "storage_ip", "")
      external_ip      = lookup(each.value, "external_ip", "")
      mgmt_gateway     = "192.168.1.1"
      storage_gateway  = "192.168.2.1"
      external_gateway = "192.168.100.1"
      ssh_pub_key      = var.ssh_public_key
    }
  )
}

# Virtual machines
resource "libvirt_domain" "vms" {
  for_each  = local.vm_configs
  name      = each.key
  memory    = each.value.memory
  vcpu      = each.value.cpus
  autostart = true

  depends_on = [
    libvirt_network.management,
    libvirt_network.storage,
  ]

  # Root disk
  disk {
    volume_id = libvirt_volume.root_volumes[each.key].id
  }

  # NFS export disk (nfs-01 only)
  dynamic "disk" {
    for_each = each.key == "nfs-01" ? [1] : []
    content {
      volume_id = libvirt_volume.nfs_storage.id
    }
  }

  # PostgreSQL data disk (db-01 only)
  dynamic "disk" {
    for_each = each.key == "db-01" ? [1] : []
    content {
      volume_id = libvirt_volume.db_data.id
    }
  }

  # Cloud-init
  cloudinit = libvirt_cloudinit_disk.cloudinit[each.key].id

  # Management NIC (primary — Kubernetes API, SSH, application traffic)
  network_interface {
    network_id     = libvirt_network.management.id
    addresses      = [each.value.mgmt_ip]
    wait_for_lease = false
  }

  # Storage NIC (cp-01, workers, nfs-01, db-01 — NFS and replication traffic)
  dynamic "network_interface" {
    for_each = contains(["cp-01", "w-01", "w-02", "nfs-01", "db-01"], each.key) ? [1] : []
    content {
      network_id     = libvirt_network.storage.id
      addresses      = [each.value.storage_ip]
      wait_for_lease = false
    }
  }

  # External NIC (lb-01 only — ingress traffic from outside)
  dynamic "network_interface" {
    for_each = each.key == "lb-01" ? [1] : []
    content {
      network_id     = libvirt_network.external.id
      addresses      = [each.value.external_ip]
      wait_for_lease = false
    }
  }

  graphics {
    type        = "vnc"
    listen_type = "address"
    autoport    = true
  }

  video {
    type = "virtio"
  }

  console {
    type        = "pty"
    target_port = "0"
  }

  cpu {
    mode = "host-passthrough"
  }

  provisioner "remote-exec" {
    inline = ["echo 'VM ${each.key} provisioned'"]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = base64decode(var.ssh_private_key)
      host        = each.value.mgmt_ip
      timeout     = "5m"
      agent       = false
    }
  }
}
