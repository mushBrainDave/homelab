#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Orchestrate a full environment bring-up from WSL, in order:
#   1. resolve the Proxmox API token (SOPS, else env var)
#   2. Terraform: select workspace, init, apply  (guests: LXCs + ubuntu VM)
#   3. HAOS: run scripts/haos-vm-create.sh on the node over SSH
#   4. Ansible: converge site.yml
#
# Usage:
#   scripts/spin-up.sh <test|prod> [--plan-only] [--skip-haos] [--skip-ansible] [--yes]
#
# Token resolution (in order):
#   • $TF_VAR_pve_api_token_secret if already exported
#   • else `sops -d` of secrets/secrets.sops.yaml -> proxmox.api_token_secret
#     (needs sops+age installed and the age key at ~/.config/sops/age/keys.txt
#     or $SOPS_AGE_KEY_FILE)
#
# Notes / current limitations:
#   • Re-runnable: Terraform + Ansible are idempotent; safe to run again.
#   • test container IPs are DHCP and not in inventory_test.yml — fill them (or
#     switch them to static) if you want the mqtt/pihole test hosts converged.
#   • prod uses *.lan names (pihole DNS). On a bare rebuild converge `dns` first.
#   • prod HAOS + node commands need sudo on the node (interactive password).
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ENV="${1:-}"
[ $# -ge 1 ] && shift || true
case "$ENV" in
  test | prod) ;;
  *)
    echo "Usage: $0 <test|prod> [--plan-only] [--skip-haos] [--skip-ansible] [--yes]" >&2
    exit 1
    ;;
esac

PLAN_ONLY=false SKIP_HAOS=false SKIP_ANSIBLE=false ASSUME_YES=false
for arg in "$@"; do
  case "$arg" in
    --plan-only) PLAN_ONLY=true ;;
    --skip-haos) SKIP_HAOS=true ;;
    --skip-ansible) SKIP_ANSIBLE=true ;;
    --yes | -y) ASSUME_YES=true ;;
    *)
      echo "Unknown flag: $arg" >&2
      exit 1
      ;;
  esac
done

# ── per-environment configuration ───────────────────────────────────────────
if [ "$ENV" = "test" ]; then
  WORKSPACE="default"
  TFVARS="environments/test.local.tfvars"
  INVENTORY="inventory_test.yml"
  NODE_SSH="root@pve.test" # root, no sudo needed
  NODE_SUDO=""
  HAOS_VMID=104
  HAOS_MAC="" # auto MAC on the test box (avoids colliding with prod HAOS)
else
  WORKSPACE="prod"
  TFVARS="environments/prod.tfvars"
  INVENTORY="inventory.yml"
  NODE_SSH="pve"      # ~/.ssh/config alias -> mushbrainssh@pve.lan
  NODE_SUDO="sudo"    # prod node cmds need root
  HAOS_VMID=103
  HAOS_MAC="BC:24:11:CF:95:10" # fixed MAC pins prod's .133 lease
fi
HAOS_VER="15.2"

say() { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die() {
  printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2
  exit 1
}

say "Environment: $ENV  (workspace=$WORKSPACE)"

# ── preflight ───────────────────────────────────────────────────────────────
command -v tofu >/dev/null || die "tofu not found on PATH"
command -v ansible-playbook >/dev/null || die "ansible-playbook not found on PATH"
[ -f "terraform/$TFVARS" ] || die "missing terraform/$TFVARS (cp the .example and edit)"
[ -f "ansible/$INVENTORY" ] || die "missing ansible/$INVENTORY"

# ── resolve the Proxmox API token secret ────────────────────────────────────
SOPS_FILE="secrets/secrets.sops.yaml"
if [ -z "${TF_VAR_pve_api_token_secret:-}" ]; then
  if command -v sops >/dev/null && [ -f "$SOPS_FILE" ]; then
    say "Decrypting Proxmox token from $SOPS_FILE"
    TF_VAR_pve_api_token_secret="$(sops -d --extract '["proxmox"]["api_token_secret"]' "$SOPS_FILE")" \
      || die "sops decrypt failed (age key at ~/.config/sops/age/keys.txt or \$SOPS_AGE_KEY_FILE?)"
    export TF_VAR_pve_api_token_secret
  else
    die "no Proxmox token. Export TF_VAR_pve_api_token_secret, or set up SOPS (install sops+age, create $SOPS_FILE with proxmox.api_token_secret)."
  fi
fi

# ── Terraform ───────────────────────────────────────────────────────────────
say "Terraform ($ENV)"
pushd terraform >/dev/null
tofu workspace select "$WORKSPACE" 2>/dev/null || tofu workspace new "$WORKSPACE"
tofu init -input=false >/dev/null

if $PLAN_ONLY; then
  tofu plan -var-file="$TFVARS"
  popd >/dev/null
  say "plan-only: stopping before apply"
  exit 0
fi

apply_args=(-var-file="$TFVARS")
$ASSUME_YES && apply_args+=(-auto-approve)
tofu apply "${apply_args[@]}"
popd >/dev/null

# ── HAOS (appliance built by the script; not Terraform-managed) ──────────────
if ! $SKIP_HAOS; then
  say "HAOS VM $HAOS_VMID on node ($NODE_SSH)"
  tr -d '\r' <scripts/haos-vm-create.sh \
    | ssh "$NODE_SSH" "${NODE_SUDO} bash -s $HAOS_VMID $HAOS_VER $HAOS_MAC"
fi

# ── Ansible ─────────────────────────────────────────────────────────────────
if ! $SKIP_ANSIBLE; then
  export ANSIBLE_CONFIG="$REPO_ROOT/ansible/ansible.cfg"
  pushd ansible >/dev/null
  say "Waiting for the ubuntu host to accept SSH (best effort)"
  ansible -i "$INVENTORY" docker_hosts -m wait_for_connection -a 'timeout=180' || \
    echo "   (wait timed out — continuing; Ansible will report per-host status)"
  say "Ansible converge (site.yml)"
  ansible-playbook -i "$INVENTORY" site.yml -K
  popd >/dev/null
fi

say "$ENV environment ready."
