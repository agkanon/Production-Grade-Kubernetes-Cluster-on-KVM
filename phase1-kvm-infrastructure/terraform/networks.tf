# Management Network (192.168.1.0/24)
resource "libvirt_network" "management" {
  name      = "kube-management"
  mode      = "bridge"
  bridge    = var.bridge_mgmt
  autostart = true
  addresses = ["192.168.1.0/24"]

  dns {
    enabled    = true
    local_only = false
  }

  dhcp {
    enabled = false
  }
}

# Storage Network (192.168.2.0/24)
resource "libvirt_network" "storage" {
  name      = "kube-storage"
  mode      = "bridge"
  bridge    = var.bridge_storage
  autostart = true
  addresses = ["192.168.2.0/24"]

  dns {
    enabled = false
  }

  dhcp {
    enabled = false
  }
}

# External Network (192.168.100.0/24)
resource "libvirt_network" "external" {
  name      = "kube-external"
  mode      = "bridge"
  bridge    = var.bridge_external
  autostart = true
  addresses = ["192.168.100.0/24"]

  dns {
    enabled = false
  }

  dhcp {
    enabled = false
  }
}
