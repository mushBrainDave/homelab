# Fresh cloud-init Ubuntu VM for the TEST environment only (count-gated on
# var.create_test_vm). Unlike the prod `ubuntu` VM (import-only), this one is
# fully declarative so `tofu apply` on the spare box provisions a real, bootable
# target that Ansible then converges — the true end-to-end IaC test.

resource "proxmox_virtual_environment_download_file" "ubuntu_cloud_img" {
  # Shared by the prod ubuntu VM and the test VM (both import their boot disk
  # from it), so it is not env-gated.
  # Must be "import" (not "iso") so it can be used as a VM disk import source on
  # PVE 8.2+/9. Requires the `import` content type enabled on the datastore
  # (local already has it). content iso -> disk import is rejected as wrong type.
  content_type = "import"
  datastore_id = "local"
  node_name    = var.pve_node
  url          = var.ubuntu_cloud_image_url
  # Ubuntu's cloud ".img" is actually QCOW2. The `import` content type rejects a
  # `.img` extension ("invalid filename or wrong extension"), so store it as
  # `.qcow2` — matching its real format — to pass Proxmox's extension check.
  file_name = "noble-server-cloudimg-amd64.qcow2"
  overwrite = false
}

resource "proxmox_virtual_environment_vm" "ubuntu_test" {
  count     = var.create_test_vm ? 1 : 0
  node_name = var.pve_node
  vm_id     = var.test_vm_id
  name      = "ubuntu-test"
  tags      = ["iac", "test"]

  # The stock Ubuntu cloud image ships no qemu-guest-agent, so leaving this on
  # makes the provider hang ~30 min waiting for the agent, then fail. Off for the
  # test VM — the guest still boots, runs cloud-init (user + SSH key + DHCP), and
  # is reachable; find its IP via the DHCP leases. To re-enable the agent, first
  # install it via a cloud-init vendor-data snippet.
  agent { enabled = false }

  cpu {
    cores = var.test_vm_cores
    type  = "host"
  }

  memory {
    dedicated = var.test_vm_memory
  }

  disk {
    datastore_id = var.datastore
    import_from  = proxmox_virtual_environment_download_file.ubuntu_cloud_img.id
    interface    = "scsi0"
    size         = var.test_vm_disk_size
  }

  # OPTIONAL Intel iGPU passthrough (VAAPI decode + OpenVINO-GPU detect).
  # VFIO passthrough is fiddly and the host loses the iGPU, so it's off by
  # default — the test Frigate config uses the OpenVINO *CPU* device, which
  # needs no /dev/dri. To enable: create a PCI resource mapping named "igpu"
  # in the Proxmox UI (Datacenter > Resource Mappings), then uncomment:
  # hostpci {
  #   device  = "hostpci0"
  #   mapping = "igpu"
  #   pcie    = true
  # }

  network_device {
    bridge = "vmbr0"
  }

  initialization {
    datastore_id = var.datastore
    ip_config {
      ipv4 {
        address = var.test_vm_ip
        gateway = var.test_vm_ip == "dhcp" ? null : var.test_vm_gateway
      }
    }
    # A static IP means no DHCP-provided resolver, so set DNS explicitly
    # (pihole first, router fallback) or apt/name resolution fails in the guest.
    dns {
      servers = ["192.168.0.50", "192.168.0.1"]
    }
    user_account {
      username = var.ci_user
      keys     = var.ci_ssh_public_key == "" ? [] : [var.ci_ssh_public_key]
    }
  }

  serial_device {} # cloud images need a serial console

  lifecycle {
    ignore_changes = [initialization] # cloud-init is one-shot; avoid churn
  }
}

output "ubuntu_test_ip" {
  value       = var.create_test_vm ? try(proxmox_virtual_environment_vm.ubuntu_test[0].ipv4_addresses, null) : null
  description = "DHCP address(es) of the test VM once the agent reports in"
}
