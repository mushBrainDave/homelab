# Home Assistant OS (VM 103 · 192.168.0.133 · homeassistant.local)

HAOS is an **appliance** — you don't manage it with Ansible/Terraform. It's
codified in two complementary ways:

## 1. The VM shell → `scripts/haos-vm-create.sh`
Rebuilds the VM (id 103) from the official image. Uses an **e1000** NIC on
purpose — the virtio NIC caused intermittent `Corrupted MAC on input` SSH
failures on this host.

## 2. The HA configuration → checked in here
Home Assistant's own config is YAML. To version it, copy these out of `/config`
(via the **Advanced SSH & Web Terminal** add-on or Samba) into this folder:

```
homeassistant/
├── configuration.yaml
├── automations.yaml
├── scripts.yaml
├── scenes.yaml
└── packages/            # optional split config
```

**Do NOT commit:**
- `secrets.yaml` (use HA's secrets mechanism; keep it git-ignored)
- `.storage/` (UI-managed state, tokens, the SQLite recorder DB) — this is
  runtime state, restore it from an HA **Backup**, not from git.

## 3. Add-ons / HACS / integrations
UI-driven and not fully declarative. Record what's installed here so a rebuild
is reproducible:

- **Add-ons:** Advanced SSH & Web Terminal, (Mosquitto broker is external — LXC 101)
- **HACS:** Frigate integration, Frigate Card
- **Integrations:** MQTT → `192.168.0.49:1883` (anonymous), Frigate → `http://192.168.0.183:5000`

## Rebuild order
1. `scripts/haos-vm-create.sh` on pve → onboard HA.
2. Restore the latest HA **Backup** (fastest path — brings config + add-ons + state).
3. Or, from scratch: install add-ons/HACS above, drop these YAML files into
   `/config`, add the MQTT + Frigate integrations.
