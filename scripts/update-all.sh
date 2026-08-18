#!/usr/bin/env bash
#
# Pull every box to the latest: apt update + full-upgrade + autoremove on each
# host in turn. Infra boxes run first; the live-workload boxes (pi5 experiments,
# zero video->mediamtx, zeroDesktop SDR) run LAST so you can Ctrl-C after the
# infra hosts finish and handle the live ones by hand if you want.
#
# The sudo password is prompted once (read -s, never stored) and reused for
# every host -- assumes the same password across the fleet. If a host uses a
# different one, sudo there just fails and the script moves on.
#
# Reboots are never automatic: a host that flags /var/run/reboot-required is
# reported, and you're asked y/N before it reboots.
#
# This is an interactive personal utility, not a cron job. Run it by hand.
set -uo pipefail   # NOT -e: one bad host must not abort the whole run

# --- host order: infra first, live-workload boxes last -----------------------
HOSTS=(
  mqtt
  pihole
  ubuntu
  pve
  pve.test
  # --- live workloads below; Ctrl-C above this line to stop before them ---
  pi5          # experimentation box
  zero         # video -> mediamtx
  zeroDesktop  # SDR broadcast
)

# --- remote payload (runs as root via `sudo bash`, so update needs no extra
#     passwordless rule). Emits UPGRADABLE=<n> and REBOOT_REQUIRED=yes|no. -----
read -r -d '' REMOTE <<'EOF' || true
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq || true
UPG=$(apt list --upgradable 2>/dev/null | grep -c "/" || true)
echo "UPGRADABLE=${UPG}"
if [ "${UPG:-0}" -gt 0 ]; then
  apt-get -y \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    full-upgrade
fi
# autoremove independently of upgrades: simulate first to count packages
# earmarked for removal (orphaned deps, and any old kernels the upgrade above
# just orphaned), and only run the real autoremove when there's something.
AR=$(apt-get -s autoremove 2>/dev/null | grep -oP '\d+(?= to remove)' | head -1)
AR=${AR:-0}
echo "AUTOREMOVE=${AR}"
if [ "$AR" -gt 0 ]; then
  apt-get -y autoremove
fi
if [ -f /var/run/reboot-required ]; then
  echo "REBOOT_REQUIRED=yes"
else
  echo "REBOOT_REQUIRED=no"
fi
EOF

# base64 the payload so quoting survives the ssh -> sudo -> bash journey intact.
ENC=$(printf '%s' "$REMOTE" | base64 | tr -d '\n')

read -rsp "sudo password (reused for all hosts): " SUDO_PASS
echo

failed=()
rebooted=()
reboot_pending=()
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

for host in "${HOSTS[@]}"; do
  echo
  echo "================================================================"
  echo ">> $host"
  echo "================================================================"

  # Password is the first stdin line (consumed by `sudo -S`); the payload runs
  # as root and reads no stdin. Output is streamed live and captured via tee.
  printf '%s\n' "$SUDO_PASS" \
    | ssh -o ConnectTimeout=10 "$host" \
        "sudo -S -p '' bash -c 'echo $ENC | base64 --decode | bash'" 2>&1 \
    | tee "$tmp"
  rc=${PIPESTATUS[1]}

  if [ "$rc" -ne 0 ]; then
    echo ">> $host: FAILED (ssh/sudo exit $rc)"
    failed+=("$host")
    continue
  fi

  if grep -q '^REBOOT_REQUIRED=yes' "$tmp"; then
    read -rp ">> $host needs a reboot. Reboot now? [y/N] " ans </dev/tty
    if [[ "$ans" =~ ^[Yy]$ ]]; then
      printf '%s\n' "$SUDO_PASS" \
        | ssh "$host" "sudo -S -p '' systemctl reboot" \
        || echo ">> $host: reboot command sent (connection dropped, as expected)"
      rebooted+=("$host")
    else
      reboot_pending+=("$host")
    fi
  fi
done

# --- summary -----------------------------------------------------------------
echo
echo "================================================================"
echo ">> Done."
[ ${#failed[@]}         -gt 0 ] && echo "   Failed:            ${failed[*]}"
[ ${#rebooted[@]}       -gt 0 ] && echo "   Rebooted:          ${rebooted[*]}"
[ ${#reboot_pending[@]} -gt 0 ] && echo "   Reboot still due:  ${reboot_pending[*]}"
[ ${#failed[@]} -eq 0 ] && [ ${#reboot_pending[@]} -eq 0 ] && echo "   All hosts current."
exit 0
