# Testing the IaC on a spare Proxmox box

Target: the unused 10th-gen i5 / 16 GB machine. Bare-metal Proxmox (no nested
virt). This validates the **full** stack — Terraform provisioning included —
without touching production.

## Resource budget (16 GB is plenty)

| Guest | Type | RAM | |
|---|---|---|---|
| Proxmox host | — | ~2 GB | install as **ext4/LVM**, not ZFS |
| mqtt | LXC | 512 MB | |
| pihole | LXC | 512 MB | optional |
| ubuntu-test (VM 900) | VM | 4 GB | Terraform-created |
| haos | VM | 2–4 GB | optional |
| **peak** | | **~9–11 GB** | 5–7 GB headroom |

> **ZFS warning:** on 16 GB, ZFS ARC can grab ~8 GB. Pick **ext4/LVM** at install
> (matches prod `local-lvm`), or cap ARC to ~2 GB.

## 0. Prep the test host

1. Install Proxmox VE (ext4/LVM). The **node name = the hostname**. If it came
   up as `pve` (collides with prod's SSH alias), rename it **now while empty** —
   trivial with no guests, painful later. As root:
   ```bash
   hostnamectl set-hostname pvetest
   sed -i 's/\bpve\b/pvetest/g' /etc/hosts   # verify the host line maps IP -> pvetest
   reboot
   # after reboot, remove the stale empty node dir:
   rm -rf /etc/pve/nodes/pve
   ```
   Then use `pvetest` as `pve_node` everywhere. (Prod's node, for reference, is
   named `mushbrain`.)
2. Download a container template for the LXCs:
   ```bash
   pveam update && pveam download local debian-12-standard_12.7-1_amd64.tar.zst
   ```
3. Create an API token for Terraform:
   ```bash
   pveum user add terraform@pve
   pveum aclmod / -user terraform@pve -role Administrator
   pveum user token add terraform@pve iac --privsep 0   # copy the secret
   ```

## 1. Static validation (do first — no infra, run from anywhere)

```bash
ansible-lint ansible/
docker compose -f docker/frigate/docker-compose.test.yml config
cd terraform && tofu init -backend=false && tofu validate
```

## 2. Provision guests with Terraform

```bash
cd terraform
cp environments/test.tfvars.example environments/test.local.tfvars   # edit IPs/node/key
export TF_VAR_pve_api_token_secret='xxxxxxxx-....'           # from step 0.3
tofu init
tofu plan  -var-file=environments/test.local.tfvars
tofu apply -var-file=environments/test.local.tfvars
```

This creates the `mqtt`/`pihole` LXCs and the fresh **ubuntu-test** VM (900).
`tofu output ubuntu_test_ip` gives its DHCP address once the guest agent is up.

## 3. Converge with Ansible

Fill the discovered IPs into `ansible/inventory_test.yml`, then:

```bash
cd ansible
ansible-playbook -i inventory_test.yml site.yml -K --limit brokers        # mosquitto
ansible-playbook -i inventory_test.yml site.yml -K --limit docker_hosts   # docker+mediamtx+nginx+pocketbase
# (skip/limit pihole unless you want a second DNS server on the LAN)
```

`-K` prompts for the sudo password (every host needs it except `apt update`).

## 4. Deploy + verify Frigate (GPU-less)

On **ubuntu-test**:
```bash
cd ~/stacks/frigate                 # synced there by the docker_host role
cp config/config.test.yml config/config.yml
# edit config.yml: set mqtt host + a real RTSP source for test_cam
docker compose -f docker-compose.test.yml up -d
```
Then browse `http://<ubuntu-test>:5000`. Uses the **OpenVINO CPU** detector — no
NVIDIA needed. (For iGPU accel, see the notes in the compose/config files.)

**No camera handy?** Loop a sample file into mediamtx as `test_cam` (mediamtx
`runOnInit` + ffmpeg), or point at a public demo RTSP.

## 5. Verify the wiring

- `mosquitto_sub -h <mqtt-test> -t 'frigate/#' -v` → live detection topics
- `curl http://<ubuntu-test>:5000/api/stats` → `detection_fps` > 0 on motion
- `curl -I http://<ubuntu-test>/forms/` (nginx proxy) — note: the `forms` image
  is CI-built and won't be present; expect 502 unless you build/load it.

## 6. Tear down

```bash
cd terraform && tofu destroy -var-file=environments/test.local.tfvars
```
Everything is disposable — re-run from step 2 anytime.

## What this proves (and doesn't)

✅ Terraform guest provisioning · Ansible convergence from scratch · compose
deploys · reverse-proxy + MQTT + Frigate detection pipeline.

❌ The NVIDIA **tensorrt** detection path (prod hardware) and the CI-built
`forms` image — both are environment-specific, not IaC defects.
