# ─────────────────────────────────────────────────────────────────────────────
# ADOPTING EXISTING GUESTS — READ FIRST
# These resources DESCRIBE guests that already exist. Do NOT `terraform apply`
# blind, or it will try to CREATE duplicates. Import the live guests into state
# first, then apply only shows drift:
#
#   terraform import proxmox_virtual_environment_container.mqtt   pve/101
#   terraform import proxmox_virtual_environment_container.pihole pve/102
#   terraform import proxmox_virtual_environment_vm.ubuntu        pve/100
#
# The HAOS VM (103) is created from a downloaded image, not cleanly declarative —
# it lives in scripts/haos-vm-create.sh instead of Terraform.
# ─────────────────────────────────────────────────────────────────────────────

resource "proxmox_virtual_environment_container" "mqtt" {
  node_name = var.pve_node
  vm_id     = 101
  tags      = ["iac", "mqtt"]

  initialization {
    hostname = "mqtt"
    ip_config {
      ipv4 { address = "dhcp" }
    }
  }

  cpu { cores = 1 }
  memory { dedicated = 512 }

  disk {
    datastore_id = var.datastore
    size         = 8
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-12-standard_amd64.tar.zst"
    type             = "debian"
  }

  unprivileged = true
}

resource "proxmox_virtual_environment_container" "pihole" {
  node_name = var.pve_node
  vm_id     = 102
  tags      = ["iac", "pihole"]

  initialization {
    hostname = "pihole"
    ip_config {
      ipv4 { address = "dhcp" }
    }
  }

  cpu { cores = 1 }
  memory { dedicated = 256 }

  disk {
    datastore_id = var.datastore
    size         = 4
  }

  operating_system {
    template_file_id = "local:vztmpl/debian-12-standard_amd64.tar.zst"
    type             = "debian"
  }

  unprivileged = true
}

# The ubuntu application host (VM 100). Large, long-lived, GPU passthrough for
# Frigate — treat as import-only. Specs reflect the live guest:
#   9 vCPU, 8 GB RAM (balloon floor 2 GB), disks 64 GB + 32 GB on local-lvm.
resource "proxmox_virtual_environment_vm" "ubuntu" {
  node_name = var.pve_node
  vm_id     = 100
  name      = "ubuntu"
  tags      = ["iac", "docker", "frigate"]

  cpu {
    cores = 9
    type  = "host"
  }

  memory {
    dedicated = 8192
    floating  = 2048 # enables ballooning down to this floor
  }

  # Disks/PCI passthrough intentionally omitted — import the real device layout
  # rather than re-declaring it here to avoid destructive diffs.

  lifecycle {
    ignore_changes = [disk, network_device, hostpci]
  }
}
