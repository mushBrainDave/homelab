# OPNsense cold standby on pvemini

The live router is VM 105 on `pve`. The mini PC `pvemini` (192.168.0.3) keeps a
**stopped copy** of the same VM, also VM 105, restored from a `pve` vzdump backup.
It is for when `pve` is down or rebooting for a long time.

| | pve (live) | pvemini (standby) |
|---|---|---|
| WAN port (`vmbr1`) | `enp131s0` (Intel I226-V) | `nic1` |
| LAN port (`vmbr0`) | `nic0` | `nic0` |
| Starts at boot | yes | **no** (`onboot: 0`) |

The copy keeps the live VM's MAC addresses (WAN `BC:24:11:04:96:9F`, LAN
`BC:24:11:5B:D1:26`). Because of that, devices and the Nokia see the same router
after a switch, with no ARP or DHCP-lease churn.

> **Never run both at once.** Both VMs claim 192.168.0.1 with the same MAC address.

## Fail over to pvemini

1. Stop the live router (skip this if `pve` is already down):
   `ssh pve` → `sudo qm shutdown 105`
2. Nothing to recable: since 2026-11-21 `pvemini`'s `nic1` has its own
   permanent cable to the Nokia, and `nic0` goes to the ES208GP. Both WAN
   cables stay plugged in. That's safe because only one VM 105 runs at a time.
3. `ssh pvemini.root qm start 105`

   > **While [CARP-PLAN.md](CARP-PLAN.md) is half-done (since step 1),** VM 105
   > on pvemini has both NICs set `link_down=1` and new MACs, so it comes up with
   > no network. Bring the links up before (or right after) starting it:
   > `ssh pvemini.root "qm set 105 --net0 virtio=BC:24:11:10:C4:DE,bridge=vmbr1,firewall=0 --net1 virtio=BC:24:11:BA:AB:86,bridge=vmbr0,firewall=0"`.
   > The new WAN MAC means the Nokia may hand it a different `192.168.1.x`, and
   > devices may need a minute to re-learn `.1`'s MAC. After failing back, set
   > `link_down=1` again, or finish the CARP plan.
4. Wait about a minute, then check: `ping 192.168.0.1`, and open a website.

Pi-hole (CT 101) still lives on `pve`. While `pve` is down, DNS will fail unless
OPNsense hands out a fallback DNS server.

## Fail back to pve

1. `ssh pvemini.root qm shutdown 105`
2. Start the router on `pve`: `sudo qm start 105`. It also starts at boot.

## Refresh the standby copy

The copy is only as current as the backup it came from. Refresh it after
changing anything in OPNsense. The weekly vzdump runs Sundays at about 01:00
to `/mnt/pve-backup/dump` on `pve`.

```bash
f=vzdump-qemu-105-<date>.vma.zst      # newest one in /mnt/pve-backup/dump on pve
ssh pve "cat /mnt/pve-backup/dump/$f" | ssh pvemini.root "cat > /var/lib/vz/dump/$f"
ssh pvemini.root "qmrestore /var/lib/vz/dump/$f 105 --storage local-lvm --force && qm set 105 --onboot 0"
```

`qmrestore` resets `onboot` to 1 from the backup, so the `qm set` part is required.
Also re-add the standby tags and description (see `qm config 105`).
