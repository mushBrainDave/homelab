# Omada AP + switch

New TP-Link Omada gear, managed by a self-hosted Omada Software Controller:

| Device | Model | Power | Address |
|---|---|---|---|
| Controller | LXC 106 `omada` on `pve` | — | `192.168.0.4` (static), web UI `https://192.168.0.4:8043` |
| Main switch | ES208GP (8× 1G, 8× PoE+) | built-in PSU | DHCP from OPNsense → reserve `.7` (adopted 2026-11-21) |
| AP | EAP720 (Omada BE5000 Wi-Fi 7, one 2.5G port) | **PoE+ from the ES208GP** (no DC adapter) | DHCP from OPNsense → reserve `.6` |
| Spare switch | ES210X-M2 (8× 2.5G, 2× 10G SFP+, **no PoE**) | 12 V adapter | Not in use for now (adopted 2026-11-18, now *Disconnected*) |

The Archer A6 (`192.168.0.2`, AP mode) is being retired. Until it's gone, its
Wi-Fi runs alongside the Omada AP.

> **Only `pve`'s `enp131s0` may touch the Nokia.** If anything else links the
> Nokia's `192.168.1.0/24` to the LAN, devices pick up `192.168.1.x` leases
> from it (bypassing OPNsense and Pi-hole), and Omada gear on those leases
> can't reach the controller, so it never adopts. On 2026-11-21 the AP got
> `192.168.1.87` and stuck in *Adopting*, and the Nokia (`.254`) answered from
> the LAN. The leak went away when the AP was unplugged. The exact path was
> never found. Test for it after each recabling: from the controller LXC,
> `ip addr add 192.168.1.250/24 dev eth0; ping -c2 192.168.1.254; ip addr del 192.168.1.250/24 dev eth0`.
> A reply means there's a leak.

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

Target layout, with no Archer. The ES208GP is the only switch and powers the
AP over PoE+. Everything runs at 1G; the ES210X-M2 can go in later as a 2.5G
core in front of it.

```
Nokia ── pve enp131s0 (OPNsense WAN — the only thing on the Nokia)

                   ES208GP (1G, PoE+)
   ┌──────────┬──────────┬──────────┬──────────┬──────────┐
 pve nic0    pvemini    desktop     AP         spare ×3
             nic0                   (PoE+ —    (pi5 eth0,
                                    power and  etc.)
                                    data)
```

All of it is one flat 192.168.0.0/24 LAN, so nothing needs reconfiguring.
Each device keeps its IP; it just reaches the network through a different box.

### Moving off the Archer

Status (2026-11-21): all wired devices are on the ES208GP (ports 1–4:
port 1 = pve `nic0` at 1G, port 3 = the Archer, carrying its Wi-Fi clients).
No Nokia leak, internet OK. The AP is now on the ES208GP over PoE, got DHCP
`192.168.0.153`, and is *Connected* in the controller. It was already adopted,
so it reconnected by itself. The leak test is still clean with it plugged in.
Next is step 2 (Wi-Fi).

1. ~~Plug the AP into the ES208GP (Ethernet only, no DC adapter) and run the
   leak test.~~ Done.
2. Set up Wi-Fi (section 4).
3. ~~Move the wired devices from the Archer to the ES208GP one at a time. Each
   move costs that device a few seconds offline. Do `pve` last, when a short
   outage is fine: moving its `nic0` drops the router, Pi-hole and every
   guest for a few seconds.~~ Done. The ES208GP's cable to the Archer is now
   the Archer's only link.
4. Turn the Archer's Wi-Fi off and live with it for a day. Anything that
   drops off only knew the Archer's SSID: re-join it to the Omada SSID.
5. Unplug the Archer. `192.168.0.2` is then free; remove any Pi-hole record
   pointing at it.

## 3. Adopt

In the controller, **switch from Global View to the site** (top-left
dropdown), then go to **Devices**. Pending devices only show in the site's
list, not in Global View's. They show as *Pending*, with an **Adopt** icon in
the Action column. Click it on each. They go *Provisioning* → *Connected*, which
can take a few minutes, and may also update their firmware.

If one doesn't appear, or sticks in *Adopting*: check the IP the Devices page
shows. Anything outside `192.168.0.x` means the Nokia is bridged into the LAN
(see the warning at the top). Otherwise check that the LXC is up
(`ssh root@192.168.0.4 docker logs omada-controller`). Discovery is a broadcast
on UDP 29810, so the device must be on the same L2 segment. The ES208GP needs
controller 6.1 or newer (we run 6.3).

Then in OPNsense, under **Services → DHCPv4 → LAN**, add static reservations
so their addresses never change (keep them in `.2–.99`):

| Device | MAC | IP | Pi-hole record |
|---|---|---|---|
| ES208GP | `C0:3A:55:03:F1:ED` | `.7` | `omada-switch.lan` |
| EAP720 | `58:D8:12:80:C7:CE` | `.6` | `omada-ap.lan` |
| ES210X-M2 (later) | `58:D8:12:FA:1C:42` | `.5` | `omada-core.lan` |

## 4. Wi-Fi

**Settings → Wireless Networks → Create**:

- To retire the Archer with no re-joining, use the **same SSID and password**
  as the Archer. Every device moves over by itself once the Archer's Wi-Fi is
  off. (Or start with a new SSID like `<name>-7` to test the AP on its own
  first, then switch it to the Archer's name.)
- Security: WPA2/WPA3-Personal (mixed). WPA3-only and 6 GHz-style options
  lock out older ESP32 / IoT gear.
- Leave 2.4 GHz on. ESPHome, the ratgdo and most IoT devices are 2.4 GHz only.
- Channels: while the Archer's Wi-Fi is still on, pin the Omada AP to
  channels it isn't using (e.g. Archer on 2.4 GHz ch 1, Omada on ch 6 or 11),
  with a 20 MHz width on 2.4 GHz. Set them back to Auto once the Archer is gone.

## Upgrades and backups

- The image is pinned in `ansible/roles/omada/defaults/main.yml`
  (`mbentley/omada-controller:6.3`). Before bumping it, take a backup in the
  controller (**Settings → Maintenance → Backup**). Database upgrades can't be undone.
- Turn on **Settings → Maintenance → Auto Backup** too. It writes to
  `/opt/omada/data/autobackup` in the LXC. Make sure the weekly vzdump job on
  `pve` covers CT 106 (Datacenter → Backup). If the job lists VMIDs instead of
  "all", add 106 to it.
