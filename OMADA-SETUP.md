# Omada AP + switch

New TP-Link Omada gear, managed by a self-hosted Omada Software Controller:

| Device | Model | Power | Address |
|---|---|---|---|
| Controller | LXC 106 `omada` on `pve` | — | `192.168.0.4` (static), web UI `https://192.168.0.4:8043` |
| Switch | ES210X-M2 (8× 2.5G, 2× 10G SFP+, **no PoE**) | 12 V adapter | DHCP from OPNsense → reserve one |
| AP | Omada BE5000 Wi-Fi 7 (EAP723-class, one 2.5G port) | 12 V DC adapter (bought separately) | DHCP from OPNsense → reserve one |

The old TP-Link router (`192.168.0.2`) keeps its Wi-Fi on. Both run at once.

The controller only holds settings. If LXC 106 or `pve` is down, the AP and
switch keep working with the last settings it pushed to them.

## 1. Build the controller

Done 2026-11-18. To rebuild, from any Windows shell (the wrapper pulls the
token from SOPS and selects the `prod` workspace; it also downloads the Debian
12 LXC template, which pve didn't have):

```
wsl -e bash /mnt/c/Users/mushbrain/source/repos/homelab/scripts/tofu-prod.sh apply
```

Add the Pi-hole local DNS record `omada.lan → 192.168.0.4`.

Then configure it. It connects as root, so `-K` can just take an empty
password (or set `ANSIBLE_BECOME_ASK_PASS=False`):

```bash
cd /mnt/c/Users/mushbrain/source/repos/homelab/ansible && export ANSIBLE_CONFIG=$PWD/ansible.cfg
ansible-playbook site.yml -K --limit controllers
```

The first start takes a few minutes while MongoDB initialises. The playbook
waits for the web UI.

Open `https://192.168.0.4:8043`, accept the self-signed cert, and run the setup
wizard: create the admin account, one site (e.g. `Home`), country = United
States, time zone = Chicago. Skip the cloud-access step (or turn it on later if
you want the Omada app to work away from home).

## 2. Cable it up

Don't open the switch's or the AP's own web page first. Adopting from the
controller works most smoothly with factory-default devices. If one was set up
on its own, factory-reset it (hold the reset pin about 10 s).

1. **Switch:** power it on. Uplink one 2.5G port to the network (for example,
   `pve`'s `nic0` → switch, then switch → a LAN port on the TP-Link, never its
   WAN port). It gets an address from OPNsense by DHCP.
   - With no DHCP it falls back to `192.168.0.1`, which clashes with OPNsense.
     So only connect it while OPNsense is up.
2. **AP:** plug its DC adapter in and run a cable from its 2.5G port to the
   switch. It also gets a DHCP address.

> Each move of `pve`'s cable briefly drops the router and every guest. Do it
> when a short outage is fine.

## 3. Adopt

In the controller, go to **Devices**. The switch and the AP show up as
*Pending*. Click **Adopt** on each. They go *Provisioning* → *Connected*, which
can take a few minutes, and may also update their firmware.

If one doesn't appear: check it's on the same LAN/subnet as `192.168.0.4`
(discovery is a broadcast on UDP 29810), and that the LXC is up
(`ssh root@192.168.0.4 docker logs omada-controller`).

Then in OPNsense, under **Services → DHCPv4 → LAN**, add static reservations
for both MACs so their addresses never change (keep them in `.2–.99`, e.g.
`.5` = switch, `.6` = AP), and add Pi-hole records (`omada-switch.lan`,
`omada-ap.lan`).

## 4. Wi-Fi

**Settings → Wireless Networks → Create**:

- Start with a **new SSID** (for example `<name>-7`). That way you can test the AP
  on its own, and the old TP-Link's devices don't drift onto it while you set it up.
- Security: WPA2/WPA3-Personal (mixed). WPA3-only and 6 GHz-style options
  lock out older ESP32 / IoT gear.
- Leave 2.4 GHz on. ESPHome, the ratgdo and most IoT devices are 2.4 GHz only.
- Channels: since the old TP-Link stays on, pin the Omada AP to channels the
  TP-Link isn't using (e.g. TP-Link on 2.4 GHz ch 1, Omada on ch 6 or 11), with a
  20 MHz width on 2.4 GHz.

If you later want one network across both, give the Omada AP the same SSID
and password as the TP-Link. Devices will pick whichever is stronger, but
the two won't hand clients off to each other smoothly the way two Omada APs
would.

## Upgrades and backups

- The image is pinned in `ansible/roles/omada/defaults/main.yml`
  (`mbentley/omada-controller:6.3`). Before bumping it, take a backup in the
  controller (**Settings → Maintenance → Backup**). Database upgrades can't be undone.
- Turn on **Settings → Maintenance → Auto Backup** too. It writes to
  `/opt/omada/data/autobackup` in the LXC. Make sure the weekly vzdump job on
  `pve` covers CT 106 (Datacenter → Backup). If the job lists VMIDs instead of
  "all", add 106 to it.
