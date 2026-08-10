variable "pve_endpoint" {
  type        = string
  description = "Proxmox API endpoint, e.g. https://pve.lan:8006/"
  default     = "https://pve.lan:8006/"
}

variable "pve_node" {
  type        = string
  description = "Proxmox node name = the host's short hostname. PROD is 'mushbrain'; the test box is 'pvetest' (set via test.tfvars)."
  default     = "mushbrain"
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

# ── Test environment toggles ────────────────────────────────────────────────
# On the spare test Proxmox host these create a fresh, bootable Ubuntu VM so
# Ansible has a Terraform-provisioned target. Off by default so prod apply
# never touches them.
variable "create_test_vm" {
  type        = bool
  description = "Create the cloud-init Ubuntu test VM (test env only)"
  default     = false
}

variable "test_vm_id" {
  type    = number
  default = 900
}

variable "test_vm_cores" {
  type    = number
  default = 2
}

variable "test_vm_memory" {
  type    = number
  default = 4096
}

variable "test_vm_disk_size" {
  type        = number
  description = "GB"
  default     = 20
}

variable "ci_user" {
  type        = string
  description = "cloud-init username for the test VM"
  default     = "mushbrain"
}

variable "ci_ssh_public_key" {
  type        = string
  description = "SSH public key injected into the test VM"
  default     = ""
}

variable "ubuntu_cloud_image_url" {
  type    = string
  default = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}
