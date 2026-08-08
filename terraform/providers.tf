terraform {
  required_version = ">= 1.6.0"
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.66"
    }
  }
}

provider "proxmox" {
  endpoint = var.pve_endpoint # e.g. https://pve.lan:8006/
  # Prefer an API token over root password. Create on the host:
  #   pveum user add terraform@pve
  #   pveum aclmod / -user terraform@pve -role Administrator
  #   pveum user token add terraform@pve iac --privsep 0
  api_token = "${var.pve_api_token_id}=${var.pve_api_token_secret}"
  insecure  = true # self-signed cert on the homelab host

  ssh {
    agent    = true
    username = "root"
  }
}
