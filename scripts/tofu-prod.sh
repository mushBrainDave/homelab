#!/usr/bin/env bash
# Run tofu against PROD with the Proxmox token pulled from SOPS.
#   scripts/tofu-prod.sh plan
#   scripts/tofu-prod.sh apply -target='proxmox_virtual_environment_container.omada[0]'
# From Windows (cmd or PowerShell):
#   wsl -e bash /mnt/c/Users/mushbrain/source/repos/homelab/scripts/tofu-prod.sh plan
set -euo pipefail
export PATH="$HOME/.local/bin:$PATH"
cd "$(dirname "$0")/.."

if [ -z "${TF_VAR_pve_api_token_secret:-}" ]; then
  TF_VAR_pve_api_token_secret="$(sops -d --extract '["proxmox"]["api_token_secret"]' secrets/secrets.sops.yaml)"
  export TF_VAR_pve_api_token_secret
fi

cd terraform
[ "$(tofu workspace show)" = prod ] || tofu workspace select prod
cmd="$1"; shift
exec tofu "$cmd" -var-file=environments/prod.tfvars "$@"
