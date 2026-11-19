# Plan: OPNsense CARP high availability (pve + pvemini)

**Status:** plan only, nothing changed yet. Written 2026-11-16.
**Goal:** when `pve` reboots, the router on `pvemini` takes over in a few seconds,
with no cable moving and no stale standby copy. Replaces the manual cold
standby in [OPNSENSE-STANDBY.md](OPNSENSE-STANDBY.md) once done.

## What it looks like when finished

```
                 Nokia XS-2426X-A  192.168.1.254/24  (DHCP .64–.253)
                 port 4 │                  │ port 1   (new cable)
          ┌─────────────┴───┐      ┌───────┴──────────┐
          │ pve  enp131s0   │      │ pvemini  nic1    │
          │  vmbr1          │      │  vmbr1           │
          │ VM 105 "A"      │      │ VM 105 "B"       │
          │  MASTER (skew 0)│      │  BACKUP (skew 100)│
          │  vmbr0  nic0    │      │  vmbr0  nic0     │
          └─────────────┬───┘      └───────┬──────────┘
                        └── house LAN ─────┘   192.168.0.0/24
```

| | Router A (pve) | Router B (pvemini) | Shared CARP address |
|---|---|---|---|
| WAN (`vtnet0`) | `192.168.1.3` | `192.168.1.4` | **`192.168.1.2`** (VHID 2) |
| LAN (`vtnet1`) | `192.168.0.252` | `192.168.0.253` | **`192.168.0.1`** (VHID 1) |
| Web UI | https://192.168.0.252 | https://192.168.0.253 | |
| DHCP pool (Dnsmasq) | `.100–.199` | `.200–.249`, reply delay 10 s | |

- The shared addresses keep the old ones, so the Nokia, every device's gateway
  (`.1`) and anything else that points at `.1` or `192.168.1.2` stays the same.
- All four new addresses were checked free on 2026-11-16. `192.168.1.3` and `.4`
  sit below the Nokia's DHCP pool, and `.252` and `.253` sit above OPNsense's.
- Both routers are VMs with virtio NICs, so interface names match on both
  (`vtnet0` = WAN, `vtnet1` = LAN). CARP needs the assignments to be identical.

## Decisions made in this plan

1. **No state sync (pfsync) to start.** OPNsense strongly advises running pfsync
   over a dedicated cable, and neither box has a spare wired port. Without it,
   a failover drops open connections once (downloads, SSH sessions, streams
   reconnect), but routing comes back within seconds. Settings sync (XMLRPC)
   runs over the LAN, which is fine because it's authenticated HTTPS.
   *Upgrade later:* a USB NIC in each box with a direct cable gives you pfsync.
2. **Hybrid outbound NAT** with one manual rule (LAN net → WAN CARP address
   `192.168.1.2`). If NAT keeps using the interface's own address, the Nokia
   would see the source change on every failover.
3. **DHCP: split pools plus a reply delay.** That's the Dnsmasq approach
   OPNsense documents. Dnsmasq doesn't go quiet on the backup by itself.
   Router A answers right away. Router B answers only if A doesn't respond for
   10 seconds. Fixed leases (Hosts) still sync from A.
4. **Pi-hole stays on `pve` for now.** CARP keeps routing up, but DHCP still hands
   out `192.168.0.50` as the only DNS server, so names stop resolving while `pve`
   is down. Fixing that is a separate step (a second Pi-hole on `pvemini`, or
   OPNsense Unbound as a fallback DNS server).

## Before you start

- [ ] Pick a quiet time. Step 3 takes the internet down for about 5–10 minutes.
- [ ] Take a fresh config backup on the live router: System → Configuration →
      Backups → Download. Then re-encrypt it into `secrets/` as usual.
- [ ] Take a fresh vzdump of VM 105 on `pve` (Datacenter → Backup → Run now). This is the rollback.
- [ ] Run a cable from `pvemini`'s `nic1` jack to **Nokia port 1**. `vmbr1` on
      `pvemini` should then show a link (`ip -br link show vmbr1` → UP).
- [ ] Have the `pvemini` and `pve` Proxmox web consoles open. Steps 2 and 3
      re-address interfaces, so you'll use the VM console, not the web UI.

## Step 1: Give router B its own MAC addresses (pvemini, nothing live yet)

The cold-standby copy uses the same MACs as router A. With CARP both run at once,
so B needs new ones. Keep both NICs disconnected for now.

```bash
ssh pvemini.root
qm set 105 --net0 virtio,bridge=vmbr1,firewall=0,link_down=1 \
           --net1 virtio,bridge=vmbr0,firewall=0,link_down=1
qm set 105 --tags "router;carp-backup" --description "OPNsense router B (CARP backup). See CARP-PLAN.md"
qm start 105
```

(Leaving out `virtio=<MAC>` makes Proxmox generate a fresh MAC.)

## Step 2: Re-address router B (VM console on pvemini)

In the OPNsense console menu, choose **2) Set interface IP address**:
- **LAN:** `192.168.0.253/24`, no gateway. If it offers to turn on a DHCP server, answer **no**.
- **WAN:** `192.168.1.4/24`, gateway `192.168.1.254`.

Then bring the NICs up:

```bash
qm set 105 --net0 virtio=<new WAN MAC>,bridge=vmbr1,firewall=0 \
           --net1 virtio=<new LAN MAC>,bridge=vmbr0,firewall=0
# (copy the MACs from `qm config 105`; leaving link_down off re-enables them)
```

**Straight away**, open https://192.168.0.253 and set up DHCP before anything else.
B's Dnsmasq still has the full `.100–.249` pool:
- Services → Dnsmasq DNS & DHCP → General: tick **Disable HA sync**.
- DHCP ranges → LAN range: change it to `192.168.0.200–192.168.0.249` and tick **Disable HA sync**.
- Set **DHCP reply delay** to `10`.
- DHCP options: add option 3 (router) = `192.168.0.1`. Option 6 (DNS) = `192.168.0.50` should already be there.
- System → Settings → General: hostname `OPNsense-b`.

Dnsmasq checks an address is unused before offering it, so the minute or two
with two servers on the same pool is low risk.

## Step 3: Re-address router A and add the shared addresses (pve; the outage)

1. On the **VM 105 console on pve**: menu **2)** →
   LAN `192.168.0.252/24`. **Internet is down from here.**
2. Open https://192.168.0.252 (set a static IP on your desktop if DHCP stalls).
3. Interfaces → WAN: change the IPv4 address `192.168.1.2` → **`192.168.1.3`**.
   The gateway stays `WAN_GW` (`192.168.1.254`).
4. Interfaces → Virtual IPs → Settings → Add, twice:
   | Mode | Interface | Address | VHID | Advertising | Password |
   |---|---|---|---|---|---|
   | CARP | LAN | `192.168.0.1/24` | 1 | base 1 / skew 0 | (pick one) |
   | CARP | WAN | `192.168.1.2/24` | 2 | base 1 / skew 0 | (same) |
5. Firewall → Rules → LAN and WAN: add **pass, protocol CARP**, any source and destination.
6. Firewall → NAT → Outbound: select **Hybrid**. Add a rule: interface WAN,
   source LAN net, translation/target **`192.168.1.2` (WAN CARP)**.
7. Services → Dnsmasq: change the LAN range to `192.168.0.100–192.168.0.199`.
   Tick **Disable HA sync** (General and on the range). Leave reply delay empty.
   Add DHCP option 3 = `192.168.0.1`.
8. Hostname `OPNsense-a`.
9. **Internet should be back**: desktop → `ping 192.168.0.1`, `ping 1.1.1.1`.

## Step 4: Turn on settings sync (router A → B)

On **router A**, System → High Availability → Settings:
- **Synchronize Config to IP:** `192.168.0.253`
- **Remote System Username / Password:** router B's root login. A dedicated sync
  user is nicer; it needs the "System: HA node" privilege.
- Leave **Synchronize all states via** and **Synchronize Peer IP** empty (no pfsync, decision 1).
- Tick at least: Firewall rules, Aliases, NAT, **Virtual IPs**, Dnsmasq.
  *Not* the general system settings: each router keeps its own interface addresses.
- Save, then **Synchronize and reconfigure all**.

On **router B**, check that Interfaces → Virtual IPs now lists both CARP
addresses with skew **100**. The sync adds 100 to the skew on the receiving side,
which is what makes B the backup. Don't configure XMLRPC sync on B.

On `pvemini`, start router B at boot from now on:
```bash
qm set 105 --onboot 1
```

## Step 5: Test

- [ ] System → High Availability → Status: A shows **MASTER** for VHID 1 and 2, B shows **BACKUP**.
- [ ] From the desktop, run `ping -t 1.1.1.1`, then `ssh pve` → `sudo qm shutdown 105`.
      Expect a few lost pings, then replies through B. B's status page flips to MASTER.
- [ ] While B is MASTER: browse a site, renew a DHCP lease on a phone, and
      check the Nokia still reaches `192.168.1.2` (Nokia → Devices).
- [ ] `sudo qm start 105` on pve: A takes MASTER back (preempt is on by default). Pings keep flowing.
- [ ] Reboot `pve` for real once, same checks.
- [ ] **Nokia ARP watch:** if internet stalls for about a minute after a switch while
      LAN pings to `.1` work, the Nokia is holding on to the old MAC for `192.168.1.2`.
      CARP sends gratuitous ARP; if the Nokia ignores it, that's the one thing
      this plan can't fix from our side.

## Step 6: Tidy up

- Update `terraform/opnsense.tf` / `environments/prod.tfvars`: LAN/WAN
  addresses are set inside OPNsense, but write the CARP layout into the header
  comment. Router B isn't in Terraform (pvemini has no API token yet).
- Replace OPNSENSE-STANDBY.md with a short "how CARP is set up and how to
  do maintenance" note. For planned work on A: System → High Availability →
  Status → **Enter Persistent CARP Maintenance Mode** hands over to B gracefully.
- New encrypted config backups for **both** routers in `secrets/`.
- Update the Pi-hole DNS record `router` (currently `192.168.0.1`) as you see fit.
  Adding `opnsense-a` → `.252` and `opnsense-b` → `.253` helps.

## Rollback (any time)

1. On `pvemini`: `qm shutdown 105 && qm set 105 --onboot 0`.
2. On router A: delete both Virtual IPs, set outbound NAT back to Automatic.
   On the console (menu 2), set LAN to `192.168.0.1/24` and WAN to `192.168.1.2/24`
   (gateway `.254`). Then set the Dnsmasq range back to `.100–.249`.
3. If anything is stuck, restore router A from the vzdump taken in "Before you start".

## Open questions to settle before step 3

- Does anything on the Nokia (port forwards, DMZ) point at `192.168.1.2`? It
  keeps working, since `.2` becomes the shared address, but it's worth a look.
- Are both routers on the same OPNsense version? They should be: B was restored
  from A's 2026-11-15 backup. Update both together from now on.
