variable "libvirt_uri" {
  description = "libvirt connection URI"
  type        = string
  default     = "qemu:///system"
}

variable "libvirt_pool" {
  description = "libvirt storage pool name"
  type        = string
  default     = "default"
}

variable "bridge_mgmt" {
  description = "Bridge interface for management network"
  type        = string
  default     = "virbr1"
}

variable "bridge_storage" {
  description = "Bridge interface for storage network"
  type        = string
  default     = "virbr2"
}

variable "bridge_external" {
  description = "Bridge interface for external network"
  type        = string
  default     = "virbr3"
}

variable "ssh_public_key" {
  description = "SSH public key for VM access"
  type        = string
  default     = ""
}

variable "ssh_private_key" {
  description = "SSH private key for provisioning"
  type        = string
  sensitive   = true
  default     = ""
}
