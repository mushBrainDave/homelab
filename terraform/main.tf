# ─────────────────────────────────────────────────────────────────────────────
# ADOPTING EXISTING GUESTS — READ FIRST
# These resources DESCRIBE guests that already exist. Do NOT `terraform apply`
# blind, or it will try to CREATE duplicates. Import the live guests into state
# first, then apply only shows drift:
#
# The prod node is named `mushbrain` (its hostname), NOT `pve`:
#   terraform import proxmox_virtual_environment_container.mqtt   mushbrain/101
#   terraform import proxmox_virtual_environment_container.pihole mushbrain/102
#   terraform import 'proxmox_virtual_environment_vm.ubuntu[0]'   mushbrain/100
#
# The HAOS VM is created from a downloaded .qcow2.xz image, not cleanly
# declarative (Terraform can't decompress .xz), so it lives in
# scripts/haos-vm-create.sh instead of Terraform:
#   prod:  ./scripts/haos-vm-create.sh 103 15.2 BC:24:11:CF:95:10
#   test:  ./scripts/haos-vm-create.sh 104 15.2      (auto MAC on pvetest)
# ─────────────────────────────────────────────────────────────────────────────

resource "proxmox_virtual_environment_container" "mqtt" {
  node_name = var.pve_node
  vm_id     = 101
  tags      = ["iac", "mqtt"]

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

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
    template_file_id = var.lxc_template
    type             = "debian"
  }

  unprivileged = true
}

resource "proxmox_virtual_environment_container" "pihole" {
  node_name = var.pve_node
  vm_id     = 102
  tags      = ["iac", "pihole"]

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

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
    template_file_id = var.lxc_template
    type             = "debian"
  }

  unprivileged = true
}

# The ubuntu application host (VM 100). Large, long-lived, GPU passthrough for
# Frigate — treat as import-only. Specs reflect the live guest:
#   9 vCPU, 8 GB RAM (balloon floor 2 GB), disks 64 GB + 32 GB on local-lvm.
resource "proxmox_virtual_environment_vm" "ubuntu" {
  # PROD-only: this is the live prod ubuntu host (import-only). On the TEST env
  # (create_test_vm = true) we use the fresh ubuntu-test VM 900 instead, so skip
  # this one — otherwise apply creates a stray diskless VM 100 on the test box.
  count     = var.create_test_vm ? 0 : 1
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
