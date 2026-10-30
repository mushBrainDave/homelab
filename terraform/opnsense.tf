# ─────────────────────────────────────────────────────────────────────────────
# OPNsense router — VM 105. See CLAUDE.md "Current project" for the full plan.
#
# Terraform builds the empty VM and attaches the installer ISO. Installing
# OPNsense and configuring it is done by hand in the Proxmox console and the
# web UI. Its config lives in OPNsense's config.xml (back it up with SOPS).
#
# NICs (order matters: net0 = vtnet0, net1 = vtnet1 inside OPNsense):
#   net0 → vmbr1  WAN  (Intel I226-V, Nokia side)
#   net1 → vmbr0  LAN  (house network)
#
# SAFETY: the installer boots a live OPNsense with its factory config, which runs
# a DHCP server on whichever port it calls LAN. On vmbr0 that would hand out
# wrong addresses to the whole house while the TP-Link is still the router. So
# the LAN NIC starts unplugged (opnsense_lan_connected = false). Plug it in only
# after OPNsense is installed and, in the console, LAN has a temporary IP
# (e.g. 192.168.0.253) and its DHCP server is OFF.
# ─────────────────────────────────────────────────────────────────────────────

resource "proxmox_virtual_environment_download_file" "opnsense_iso" {
  content_type            = "iso"
  datastore_id            = "local"
  node_name               = var.pve_node
  url                     = "https://pkg.opnsense.org/releases/${var.opnsense_version}/OPNsense-${var.opnsense_version}-dvd-amd64.iso.bz2"
  checksum                = var.opnsense_iso_sha256 # of the .bz2, from the release's checksums file
  checksum_algorithm      = "sha256"
  decompression_algorithm = "bz2"
  file_name               = "OPNsense-${var.opnsense_version}-dvd-amd64.iso"
  overwrite               = false
  upload_timeout          = 1800 # seconds; download + bz2 decompress of a ~2 GB ISO
}

resource "proxmox_virtual_environment_vm" "opnsense" {
  node_name   = var.pve_node
  vm_id       = 105
  name        = "opnsense"
  description = "OPNsense router. WAN = net0/vmbr1 (Nokia), LAN = net1/vmbr0. Managed in terraform/opnsense.tf"
  tags        = ["iac", "router"]

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"

  # Router comes up first; Pi-hole (LXC 101) should follow it (order 2).
  on_boot = true
  startup {
    order    = 1
    up_delay = 30
  }

  # Off until the os-qemu-guest-agent plugin is installed in OPNsense; with it
  # on and no agent running, apply would hang waiting for an IP.
  agent { enabled = false }

  operating_system {
    type = "other" # FreeBSD
  }

  cpu {
    cores = 2
    type  = "host"
  }

  memory {
    dedicated = 4096
    floating  = 0 # no balloon: a router shouldn't have RAM pulled away
  }

  disk {
    datastore_id = var.datastore
    interface    = "scsi0"
    size         = 32
    ssd          = true
    discard      = "on"
    iothread     = true
  }

  cdrom {
    file_id   = proxmox_virtual_environment_download_file.opnsense_iso.id
    interface = "ide2"
  }

  # Empty disk on first boot falls through to the ISO; after install it boots
  # from the disk, so the ISO can stay attached harmlessly.
  boot_order = ["scsi0", "ide2"]

  # WAN — vtnet0
  network_device {
    bridge   = "vmbr1"
    model    = "virtio"
    firewall = false
  }

  # LAN — vtnet1. Starts unplugged; see SAFETY above.
  network_device {
    bridge       = "vmbr0"
    model        = "virtio"
    firewall     = false
    disconnected = !var.opnsense_lan_connected
  }

  lifecycle {
    # Ejecting the ISO in the Proxmox UI after install shouldn't show as drift.
    ignore_changes = [cdrom]
  }
}
