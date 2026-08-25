# Rebuilding prod (adopt current, or spin up fresh on new hardware)

The prod Terraform is now **create-capable and idempotent**: one definition either
**adopts** the live guests (via `import`) or **builds** them from scratch on new hardware.
Scope is **infrastructure + software config** — application **data** (pihole config,
pocketbase `pb_data`, HAOS config, Frigate recordings) is restored separately from your backups.

Guest map (live prod): **LXC 101 = pihole (.50)**, **LXC 102 = mqtt (.49)**, **VM 100 = ubuntu**
(Docker/Frigate), **VM 103 = HAOS (.133)**.

## One-command bring-up (orchestrator)

[scripts/spin-up.sh](scripts/spin-up.sh) runs the whole sequence — Terraform → HAOS → Ansible —
for either environment:

```bash
scripts/spin-up.sh test              # build/converge the test box
scripts/spin-up.sh prod --plan-only  # dry-run prod (safe: plan only, no apply)
scripts/spin-up.sh prod              # full prod build (new hardware)
```
Flags: `--plan-only` (stop after `tofu plan`), `--skip-haos`, `--skip-ansible`, `--yes`
(auto-approve apply). It resolves the Proxmox token from SOPS if configured, else from
`$TF_VAR_pve_api_token_secret`. The manual steps below are what the script automates — use them
when you want to run a phase by hand or debug.

## State separation (do this first)
Test and prod share this code but MUST NOT share state — the resource addresses (`.pihole`,
`.mqtt`, `.ubuntu`) are the same, so one state can't hold both. Use Terraform **workspaces**:
```bash
cd terraform
tofu workspace list                 # test work lives in "default"
tofu workspace new prod             # isolated state for prod (once); later: tofu workspace select prod
```
Run every prod command below **in the `prod` workspace**; switch back with
`tofu workspace select default` for test.

## A. Adopt the current prod box into state (idempotency check)

Run from WSL. Set the API token secret first (`export TF_VAR_pve_api_token_secret='...'`).

```bash
cd terraform
cp environments/prod.tfvars.example environments/prod.tfvars   # local working copy
tofu init
tofu import -var-file=environments/prod.tfvars proxmox_virtual_environment_container.pihole mushbrain/101
tofu import -var-file=environments/prod.tfvars proxmox_virtual_environment_container.mqtt   mushbrain/102
tofu import -var-file=environments/prod.tfvars 'proxmox_virtual_environment_vm.ubuntu[0]'   mushbrain/100
tofu plan  -var-file=environments/prod.tfvars
```

**SAFETY GATE:** the `plan` must show **no destructive changes** (no destroy/replace of any
guest). If it wants to destroy/recreate a live guest, STOP and widen `lifecycle.ignore_changes`
on that resource in [terraform/main.tf](terraform/main.tf) until the plan is clean. **Never
`apply` a dirty plan against live prod.** In-place, non-destructive nudges (e.g. adding a `tags`
line) are fine to apply.

## B. Spin up fresh on NEW hardware

1. **Install Proxmox VE** (ext4/LVM), set hostname = node name (`mushbrain`, or update
   `pve_node`). Wire it to ethernet with a bridged `vmbr0` on `nic0` (see the `proxmox` Ansible
   role for the nic0 offload fix).
2. **API token:** `pveum user add terraform@pve; pveum aclmod / -user terraform@pve -role Administrator; pveum user token add terraform@pve iac --privsep 0` → `export TF_VAR_pve_api_token_secret=...`
3. **LXC template:** `pveam update && pveam download local debian-12-standard_12.12-1_amd64.tar.zst`
4. **GPU resource mapping** (for Frigate): Datacenter → Resource Mappings → Add (PCI), name it
   `frigate-gpu`, covering the GPU's functions (on the current box `0000:02:00.0` + `0000:02:00.1`;
   re-check with `lspci -nn` on the new box). Skip by setting `gpu_mapping = ""`.
5. **Apply:**
   ```bash
   cd terraform && tofu init
   tofu apply -var-file=environments/prod.tfvars
   ```
6. **Physical media disk** (Frigate storage): the 4 TB drive passthrough is hardware-specific and
   NOT created by Terraform. Attach it manually after apply:
   `qm set 100 --scsi1 /dev/disk/by-id/<the-new-drive>,backup=0`
7. **Configure with Ansible:**
   ```bash
   cd ../ansible && ansible-playbook -i inventory.yml site.yml -K
   ```
   DNS bootstrap note: pihole is itself a managed guest, so on a bare rebuild the `*.lan` names
   won't resolve until pihole is up. Converge `dns` first (or temporarily use IPs in the
   inventory), then the rest.
   NVIDIA note: the `nvidia` role (runs on the ubuntu host because `nvidia_gpu: true` in the
   inventory) installs the in-guest driver + `nvidia-container-toolkit` + Docker `nvidia` runtime
   that Frigate's tensorrt/CUDA path needs — GPU passthrough alone does not. A **reboot** of the
   ubuntu guest is normally required after the first driver install; re-run the play (or just
   `nvidia-smi`) to confirm, then start Frigate. Defaults install `cuda-drivers` (latest
   recommended branch — best for a brand-new card); pin a branch via `nvidia_driver_package` if
   needed.
8. **HAOS:** `./scripts/haos-vm-create.sh 103 15.2 BC:24:11:CF:95:10` (run on the node).
9. **Restore data** from backups (pihole config, pocketbase `pb_data`, HAOS, Frigate media).

## Known non-reproducible-by-Terraform bits (by design)
- **Physical disk passthrough** (ubuntu `scsi1`) — hardware-specific `/dev/disk/by-id`; step B6.
- **GPU passthrough** — the *mapping* is per-box (the `frigate-gpu` resource mapping, step B4);
  the *in-guest* NVIDIA driver + container toolkit is now automated by the `nvidia` Ansible role
  (step B7), so this is no longer a manual step beyond the mapping + a post-install reboot.
- **Container TUN device** (`/dev/net/tun`) on pihole/mqtt — a raw LXC option bpg doesn't model;
  add manually if a container needs it (`pct set <id> -mp...`/`lxc.mount.entry`).
- **HAOS** — scripted (`.qcow2.xz`), not declarative.
