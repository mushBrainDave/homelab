# ─────────────────────────────────────────────────────────────────────────────
# Omada Software Controller — LXC 106 (192.168.0.4, omada.lan).
#
# Manages the TP-Link Omada gear: the BE5000 AP and the ES210X-M2 switch.
# Runs the mbentley/omada-controller Docker image (see ansible/roles/omada).
# The AP and switch keep working while this is down; you just can't change
# their settings until it's back.
#
# Docker inside an unprivileged LXC needs nesting.
# Host networking puts the controller straight on vmbr0, so it sees the Omada
# discovery broadcasts (UDP 29810) from new devices on the LAN.
#
# Root gets the desktop SSH key so Ansible can configure it right after apply.
# ─────────────────────────────────────────────────────────────────────────────

# The prod LXCs were imported, not created, so pve never had a template.
# Download it here so this container (and future fresh ones) can be built.
resource "proxmox_virtual_environment_download_file" "debian12_lxc" {
  count = var.omada_ip == "" ? 0 : 1

  content_type       = "vztmpl"
  datastore_id       = "local"
  node_name          = var.pve_node
  url                = "http://download.proxmox.com/images/system/debian-12-standard_12.12-1_amd64.tar.zst"
  checksum           = "50c85eaaece677a3ebe01cc909b83872e9da2a22c29ae652838afce71e83222fdf40f6accecd7d52b180e912fc1f85ecdf7b3fc4d3027da4d865e509a9e76597"
  checksum_algorithm = "sha512"
  file_name          = "debian-12-standard_12.12-1_amd64.tar.zst"
  overwrite          = false
}

resource "proxmox_virtual_environment_container" "omada" {
  count = var.omada_ip == "" ? 0 : 1

  node_name = var.pve_node
  vm_id     = 106
  tags      = ["iac", "omada"]

  # keyctl would need root@pam (the API token gets a 403); Docker runs
  # without it. If it's ever needed: `sudo pct set 106 --features nesting=1,keyctl=1`
  # on pve (features is in ignore_changes so that won't drift).
  features {
    nesting = true
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  initialization {
    hostname = "omada"
    ip_config {
      ipv4 {
        address = var.omada_ip
        gateway = var.omada_ip == "dhcp" ? null : var.lan_gateway
      }
    }
    dns {
      servers = var.dns_servers
    }
    user_account {
      keys = var.ci_ssh_public_key == "" ? [] : [var.ci_ssh_public_key]
    }
  }

  # The controller (Java + MongoDB) wants ~2 GB; give it headroom.
  cpu { cores = 2 }
  memory {
    dedicated = 3072
    swap      = 1024
  }

  disk {
    datastore_id = var.datastore
    size         = 16
  }

  operating_system {
    template_file_id = proxmox_virtual_environment_download_file.debian12_lxc[0].id
    type             = "debian"
  }

  # After OPNsense (1) and Pi-hole (2).
  startup {
    order = 3
  }

  start_on_boot = true
  unprivileged  = true

  lifecycle {
    ignore_changes = [initialization, operating_system, console, features]
  }
}
