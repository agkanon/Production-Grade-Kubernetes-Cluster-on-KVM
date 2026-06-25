output "vm_mgmt_ips" {
  description = "Management IP addresses of all VMs"
  value = {
    for name, vm in libvirt_domain.vms :
    name => vm.network_interface[0].addresses[0]
  }
}

output "vm_details" {
  description = "Complete details of deployed VMs"
  value = {
    for name, vm in libvirt_domain.vms :
    name => {
      cpus     = vm.vcpu
      memory   = vm.memory
      mgmt_ip  = vm.network_interface[0].addresses[0]
      role     = local.vm_configs[name].role
    }
  }
}

output "network_details" {
  description = "Network configuration details"
  value = {
    management = {
      name    = libvirt_network.management.name
      bridge  = var.bridge_mgmt
      network = "192.168.1.0/24"
      gateway = "192.168.1.1"
    }
    storage = {
      name    = libvirt_network.storage.name
      bridge  = var.bridge_storage
      network = "192.168.2.0/24"
      gateway = "192.168.2.1"
    }
    external = {
      name    = libvirt_network.external.name
      bridge  = var.bridge_external
      network = "192.168.100.0/24"
      gateway = "192.168.100.1"
    }
  }
}
