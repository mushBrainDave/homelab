#!/usr/bin/env bash
# Create/recreate a Home Assistant OS VM on a Proxmox host.
# Run as root ON the node. HAOS ships as a .qcow2.xz image, so this is a scripted
# build rather than Terraform. Idempotency is minimal — intended for rebuilds.
#
# Usage: ./haos-vm-create.sh [VMID] [VERSION] [MAC]
#   prod:  ./haos-vm-create.sh 103 15.2 BC:24:11:CF:95:10   # fixed MAC keeps .133 lease
#   test:  ./haos-vm-create.sh 104 15.2                     # no MAC = auto (avoids LAN collision)
set -euo pipefail

VMID="${1:-103}"
VER="${2:-15.2}"          # HAOS release
MAC="${3:-}"              # empty = Proxmox auto-generates (use a fixed MAC only to pin a DHCP lease)
STORAGE="local-lvm"
BRIDGE="vmbr0"

# Same MAC on two powered-on VMs on the same LAN = conflict. Only pin it for prod.
if [ -n "$MAC" ]; then NETDEV="e1000=${MAC},bridge=${BRIDGE}"; else NETDEV="e1000,bridge=${BRIDGE}"; fi

cd /tmp
wget -nc "https://github.com/home-assistant/operating-system/releases/download/${VER}/haos_ova-${VER}.qcow2.xz"
[ -f "haos_ova-${VER}.qcow2" ] || unxz "haos_ova-${VER}.qcow2.xz"

qm create "$VMID" --name haos --ostype l26 --machine q35 \
  --cpu host --cores 2 --memory 4096 --balloon 2048 \
  --bios ovmf --scsihw virtio-scsi-single --agent 1 \
  --net0 "$NETDEV"    # e1000 avoids the virtio SSH-MAC corruption

qm set "$VMID" --efidisk0 "${STORAGE}:0,efitype=4m,pre-enrolled-keys=0"
qm importdisk "$VMID" "haos_ova-${VER}.qcow2" "$STORAGE"
qm set "$VMID" --scsi0 "${STORAGE}:vm-${VMID}-disk-1"
qm set "$VMID" --boot order=scsi0
qm disk resize "$VMID" scsi0 32G
qm set "$VMID" --onboot 1
qm start "$VMID"

echo "HAOS ${VER} starting as VM ${VMID}. Onboarding at http://homeassistant.local:8123"
