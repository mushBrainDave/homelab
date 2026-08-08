variable "pve_endpoint" {
  type        = string
  description = "Proxmox API endpoint, e.g. https://pve.lan:8006/"
  default     = "https://pve.lan:8006/"
}

variable "pve_node" {
  type    = string
  default = "pve"
}

variable "pve_api_token_id" {
  type      = string
  sensitive = true
}

variable "pve_api_token_secret" {
  type      = string
  sensitive = true
}

variable "datastore" {
  type        = string
  description = "LVM-thin pool for guest disks"
  default     = "local-lvm"
}
