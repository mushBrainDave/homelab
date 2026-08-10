# Homelab — Infrastructure as Code

Declarative-ish definition of a single-node Proxmox homelab. Goal: **~80%
rebuildable from git**, with the stateful remainder covered by backups.

> ⚠️ **Security — rotate the Anthropic API key.** The `forms` container was
> found exposing a live `ANTHROPIC_API_KEY` in its environment, and it may be
> baked into the CI-built image layers. Rotate it in the Anthropic console and
> inject it only at runtime via `docker/forms/.env` (git-ignored) / SOPS.
> Nothing real is committed in this repo — see [Secrets](#secrets).

## Topology

```
Proxmox host  pve.lan  (Core Ultra 5 225 · 10c · 30 GiB · NVMe 815 GB thin pool)
│  nic0 → vmbr0   (offload disabled — fixes intermittent SSH "Corrupted MAC")
│
├─ VM  100  ubuntu   192.168.0.183   Docker + native services
│     ├─ frigate    (docker)  :5000   NVR, GPU detect  → MQTT + /recordings
│     ├─ forms      (docker)  :8080   .NET app (CI-built image)  ⚠ API key
│     ├─ mediamtx   (systemd) :8554   RTSP restream of Pi cameras
│     ├─ pocketbase (systemd) :8090   datastore
│     ├─ nginx      (systemd) :80     reverse proxy (/pb /forms /cla /cod /mqtt)
│     └─ actions-runner        —      self-hosted GitHub CI (builds forms)
│
├─ LXC 101  mqtt     192.168.0.49    Mosquitto (1883 + ws 9001, anonymous)
├─ LXC 102  pihole   192.168.0.50    Pi-hole v6 DNS
└─ VM  103  haos     192.168.0.133   Home Assistant OS (appliance, e1000 NIC)

Cameras: Raspberry Pis (zero, pi5, …) publish RTSP → mediamtx → Frigate.
```

## Repo layout

| Path | What | Tool |
|------|------|------|
| `terraform/` | Proxmox guests (LXCs, ubuntu VM) | OpenTofu / Terraform + `bpg/proxmox` |
| `scripts/haos-vm-create.sh` | HAOS VM (image-based, not TF) | bash on pve |
| `ansible/` | OS + native services (mosquitto, mediamtx, nginx, pocketbase, pihole, host tweaks) | Ansible |
| `docker/` | Container stacks (frigate, forms) | Docker Compose |
| `homeassistant/` | HA config + rebuild notes | (appliance) |
| `secrets/` | SOPS-encrypted secrets | SOPS + age |

## Prerequisites

```bash
# On your workstation
winget install OpenTofu.OpenTofu     # or Terraform
pipx install ansible-core
winget install FiloSottile.age Mozilla.sops
```

## Secrets

Never commit plaintext. Secrets live in `secrets/secrets.sops.yaml` (encrypted).

```bash
age-keygen -o ~/.config/sops/age/keys.txt      # one-time; note the age1... pubkey
# put the pubkey in .sops.yaml
cp secrets/secrets.sops.example.yaml secrets/secrets.sops.yaml
sops -e -i secrets/secrets.sops.yaml           # encrypt in place
sops secrets/secrets.sops.yaml                 # edit thereafter
```

Consumers:
- `docker/forms/.env` ← `sops -d … | yq '.forms'` (ANTHROPIC_API_KEY)
- Terraform ← `TF_VAR_pve_api_token_secret=$(sops -d … | yq '.proxmox.api_token_secret')`

## Bootstrap order (rebuild from bare Proxmox)

1. **Guests** — `cd terraform && tofu init && tofu apply` (creates LXCs).
   For the existing ubuntu VM, `tofu import` rather than recreate (see `main.tf`).
2. **HAOS** — `scripts/haos-vm-create.sh` on pve.
3. **Config** — `cd ansible && ansible-playbook site.yml -K`
   (`-K` because sudo needs a password on every host except `apt update`).
4. **Containers** — on ubuntu: render `forms/.env` from SOPS, then
   `docker compose up -d` in each `stacks/*` dir (Ansible syncs them there).
5. **Home Assistant** — restore latest HA Backup, or follow `homeassistant/README.md`.

## Testing

Validate changes on a throwaway Proxmox box before touching prod — see
[TESTING.md](TESTING.md). The `test` Terraform profile
(`terraform/environments/test.tfvars.example`) provisions fresh guests + a GPU-less
Frigate (`docker/frigate/*.test.yml`, OpenVINO CPU) so the whole pipeline can be
exercised end-to-end and torn down with `tofu destroy`.

## What is NOT in git (restore from backups)

- Frigate recordings + `frigate.db`, HA recorder DB, Pi-hole query DB, PocketBase `pb_data/`.
- The `forms` **image** (built from a separate app repo by the Actions runner).
- HA `.storage/` (tokens, UI state).

## Adoption is incremental & non-destructive

This repo was captured from the **live** systems as-is (Phase 0). You can commit
it and push without changing anything on the servers. Layer in Terraform
import → Ansible convergence → CI at your own pace.

## Known quirks captured here

- **NIC offload** disabled on `nic0` (Proxmox) — else SSH to guests intermittently
  dies with `Corrupted MAC on input`. (`ansible/roles/proxmox`)
- **HAOS uses an e1000 NIC**, not virtio, for the same reason. (`scripts/haos-vm-create.sh`)
- **Mosquitto is anonymous** on the LAN — fine for now; credential path stubbed in secrets.
- **Sudo** needs a password everywhere except `sudo apt update`. (`ansible/roles/common`)
