# ─────────────────────────────────────────────────────────────────────────────
# One declarative definition serves BOTH environments:
#   • Fresh build (new hardware / test): `tofu apply` CREATES these guests.
#   • Existing prod: `tofu import` adopts the live guests; `ignore_changes`
#     absorbs the hand-built bits (disks, cloud-init, GPU) so plan shows no
#     destructive diffs. Declared cpu/memory/bios/etc. are matched to live.
#
# Adopt existing PROD (node `mushbrain`, PVE 9). NOTE the VMIDs — live prod has
# pihole on 101 and mqtt on 102 (the opposite of the earlier code):
#   tofu import -var-file=environments/prod.tfvars proxmox_virtual_environment_container.pihole mushbrain/101
#   tofu import -var-file=environments/prod.tfvars proxmox_virtual_environment_container.mqtt   mushbrain/102
#   tofu import -var-file=environments/prod.tfvars 'proxmox_virtual_environment_vm.ubuntu[0]'   mushbrain/100
# Then: tofu plan -var-file=environments/prod.tfvars  → MUST show no destructive changes.
#
# HAOS (VM 103) ships as a .qcow2.xz Terraform can't decompress — it stays in
# scripts/haos-vm-create.sh:
#   prod:  ./scripts/haos-vm-create.sh 103 15.2 BC:24:11:CF:95:10
#   test:  ./scripts/haos-vm-create.sh 104 15.2
#
# Hardware-specific bits NOT reproduced by Terraform on new hardware (attach
# manually post-apply): the ubuntu VM's passed-through physical 4TB disk
# (scsi1 /dev/disk/by-id/...) and the GPU (create the resource mapping first).
# ─────────────────────────────────────────────────────────────────────────────

# pihole — LXC 101 on live prod (192.168.0.50).
resource "proxmox_virtual_environment_container" "pihole" {
  node_name = var.pve_node
  vm_id     = 101
  tags      = ["iac", "pihole"]

  features {
    nesting = true
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  initialization {
    hostname = "pihole"
    ip_config {
      ipv4 {
        address = var.pihole_ip
        gateway = var.pihole_ip == "dhcp" ? null : var.lan_gateway
      }
    }
    dns {
      servers = var.dns_servers
    }
  }

  cpu { cores = 1 }
  memory {
    dedicated = 512
    swap      = 512
  }

  disk {
    datastore_id = var.datastore
    size         = 8
  }

  operating_system {
    template_file_id = var.lxc_template
    type             = "debian"
  }

  unprivileged = true

  # Absorb the hand-built live container on import (MAC, exact IP, TUN device
  # passthrough, template) while still creating a fresh one from the vars above.
  lifecycle {
    ignore_changes = [initialization, network_interface, operating_system, console]
  }
}

# mqtt — LXC 102 on live prod (192.168.0.49).
resource "proxmox_virtual_environment_container" "mqtt" {
  node_name = var.pve_node
  vm_id     = 102
  tags      = ["iac", "mqtt"]

  features {
    nesting = true
  }

  network_interface {
    name   = "eth0"
    bridge = "vmbr0"
  }

  initialization {
    hostname = "mqtt"
    ip_config {
      ipv4 {
        address = var.mqtt_ip
        gateway = var.mqtt_ip == "dhcp" ? null : var.lan_gateway
      }
    }
    dns {
      servers = var.dns_servers
    }
  }

  cpu { cores = 1 }
  memory {
    dedicated = 256
    swap      = 256
  }

  disk {
    datastore_id = var.datastore
    size         = 4
  }

  operating_system {
    template_file_id = var.lxc_template
    type             = "debian"
  }

  unprivileged = true

  lifecycle {
    ignore_changes = [initialization, network_interface, operating_system, console]
  }
}

# The ubuntu application host (VM 100). Prod: 9 vCPU, 20 GB RAM (balloon 8 GB),
# OVMF/q35, NVIDIA GPU passthrough for Frigate, boot disk + 32 GB data disk +
# (manually attached) physical media disk. PROD-only — the test env builds the
# fresh ubuntu-test VM 900 instead, so this is count-gated off there.
resource "proxmox_virtual_environment_vm" "ubuntu" {
  count     = var.create_test_vm ? 0 : 1
  node_name = var.pve_node
  vm_id     = 100
  name      = "ubuntu"
  tags      = ["iac", "docker", "frigate"]

  # Declared to MATCH live so import shows no diff on these.
  bios          = "ovmf"
  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  on_boot       = true

  agent { enabled = false } # live prod has no guest agent

  operating_system {
    type = "l26" # Linux 2.6+ — matches live
  }

  cpu {
    cores = 9
    type  = "host"
  }

  memory {
    dedicated = 20480
    floating  = 8192
  }

  efi_disk {
    datastore_id      = var.datastore
    type              = "4m"
    pre_enrolled_keys = true
  }

  # Boot disk from the shared cloud image (used on CREATE; ignored on import).
  disk {
    datastore_id = var.datastore
    import_from  = proxmox_virtual_environment_download_file.ubuntu_cloud_img.id
    interface    = "scsi0"
    size         = 64
    ssd          = true
    discard      = "on"
    cache        = "writeback"
    iothread     = true
  }

  # 32 GB data disk (matches live scsi2). The physical 4TB passthrough (scsi1)
  # is hardware-specific and attached manually on new hardware.
  disk {
    datastore_id = var.datastore
    interface    = "scsi2"
    size         = 32
    backup       = false
    iothread     = true
  }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    datastore_id = var.datastore
    ip_config {
      ipv4 {
        address = var.ubuntu_ip
        gateway = var.ubuntu_ip == "dhcp" ? null : var.lan_gateway
      }
    }
    dns {
      servers = var.dns_servers
    }
    user_account {
      username = var.ci_user
      keys     = var.ci_ssh_public_key == "" ? [] : [var.ci_ssh_public_key]
    }
  }

  serial_device {}

  # GPU passthrough via a Datacenter resource mapping (portable across hardware).
  # Empty gpu_mapping = no passthrough. Ignored on import (live uses hostpci0).
  dynamic "hostpci" {
    for_each = var.gpu_mapping != "" ? [1] : []
    content {
      device  = "hostpci0"
      mapping = var.gpu_mapping
      pcie    = true
    }
  }

  # Absorb the hand-built live VM on import: as-built disks (incl. the physical
  # passthrough), no cloud-init drive, and the raw hostpci line.
  lifecycle {
    ignore_changes = [disk, efi_disk, initialization, network_device, hostpci, serial_device]
  }
}
