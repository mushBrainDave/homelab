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

variable "lxc_template" {
  type        = string
  description = <<-EOT
    LXC template volid for the mqtt/pihole containers. PROD adopts these
    containers import-only, so the template is never validated there and the
    version-less default is fine. TEST creates them fresh, so it must override
    this with the EXACT downloaded name (see `pveam list local`), e.g.
    local:vztmpl/debian-12-standard_12.12-1_amd64.tar.zst
  EOT
  default     = "local:vztmpl/debian-12-standard_amd64.tar.zst"
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

variable "test_vm_ip" {
  type        = string
  description = "Test VM address as CIDR (e.g. 192.168.0.90/24) for a static IP, or \"dhcp\". Static avoids DHCP-lease collisions."
  default     = "dhcp"
}

variable "test_vm_gateway" {
  type        = string
  description = "Default gateway for the test VM when test_vm_ip is a static CIDR; ignored when dhcp."
  default     = "192.168.0.1"
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

# ── Prod / shared guest addressing & passthrough ────────────────────────────
variable "lan_gateway" {
  type        = string
  description = "Default gateway for static guest IPs."
  default     = "192.168.0.1"
}

variable "dns_servers" {
  type        = list(string)
  description = "DNS servers for statically-addressed guests (router by default; add pihole once it exists)."
  default     = ["192.168.0.1"]
}

variable "mqtt_ip" {
  type        = string
  description = "Static CIDR for the mqtt container (e.g. 192.168.0.49/24) or \"dhcp\"."
  default     = "dhcp"
}

variable "pihole_ip" {
  type        = string
  description = "Static CIDR for the pihole container (e.g. 192.168.0.50/24) or \"dhcp\"."
  default     = "dhcp"
}

variable "ubuntu_ip" {
  type        = string
  description = "Static CIDR for the prod ubuntu VM (e.g. 192.168.0.183/24) or \"dhcp\"."
  default     = "dhcp"
}

variable "gpu_mapping" {
  type        = string
  description = "Proxmox Datacenter PCI resource-mapping name for GPU passthrough on the prod ubuntu VM (create it under Datacenter > Resource Mappings). Empty = no passthrough (e.g. test)."
  default     = ""
}

# ── OPNsense router (VM 105, opnsense.tf) ───────────────────────────────────
variable "opnsense_version" {
  type        = string
  description = "OPNsense release for the installer ISO (pkg.opnsense.org/releases/<version>/)."
  default     = "26.7"
}

variable "opnsense_iso_sha256" {
  type        = string
  description = "SHA256 of OPNsense-<version>-dvd-amd64.iso.bz2, from the release's OPNsense-<version>-checksums-amd64.sha256. Update together with opnsense_version."
  default     = "95cafedda6d5b22ce832e249dc2309110fbee19f813ad78cf28bb3d387186bfb"
}

variable "opnsense_lan_connected" {
  type        = bool
  description = "Plug in OPNsense's LAN NIC (vmbr0). Keep false until LAN has a non-clashing IP and its DHCP server is off. See opnsense.tf."
  default     = false
}
