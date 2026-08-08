#!/usr/bin/env bash
# Recreate the Home Assistant OS VM (id 103) on the Proxmox host.
# Run as root ON pve. HAOS ships as a qcow2 image, so this is a scripted build
# rather than Terraform. Idempotency is minimal — intended for rebuilds.
set -euo pipefail

VMID=103
VER="${1:-15.2}"          # HAOS release; override: ./haos-vm-create.sh 16.0
STORAGE="local-lvm"
BRIDGE="vmbr0"
MAC="BC:24:11:CF:95:10"   # keep the MAC so it retains its DHCP lease (.133)

cd /tmp
wget -nc "https://github.com/home-assistant/operating-system/releases/download/${VER}/haos_ova-${VER}.qcow2.xz"
[ -f "haos_ova-${VER}.qcow2" ] || unxz "haos_ova-${VER}.qcow2.xz"

qm create "$VMID" --name haos --ostype l26 --machine q35 \
  --cpu host --cores 2 --memory 4096 --balloon 2048 \
  --bios ovmf --scsihw virtio-scsi-single --agent 1 \
  --net0 "e1000=${MAC},bridge=${BRIDGE}"    # e1000 avoids the virtio SSH-MAC corruption

qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0"
qm importdisk "$VMID" "haos_ova-${VER}.qcow2" "$STORAGE"
qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-1"
qm set "$VMID" --boot order=scsi0
qm disk resize "$VMID" scsi0 32G
qm set "$VMID" --onboot 1
qm start "$VMID"

echo "HAOS ${VER} starting as VM ${VMID}. Onboarding at http://homeassistant.local:8123"
