#!/usr/bin/env bash
#
# Run `apt update` on a host (passwordless per the sudoers drop-in), and only
# if there are packages to upgrade, prompt once for the sudo password and run
# `apt upgrade`. The password is read with `read -s` (never echoed, never
# stored on disk) and fed to `sudo -S` over ssh stdin.
#
# Usage: ./update.sh [host]   (defaults to pve.test)
set -euo pipefail

HOST="${1:-pve.test}"

echo ">> $HOST: running apt update ..."
# `sudo apt update` is the one passwordless command; refresh the index, then
# count upgradable packages. `apt list --upgradable` prints a "Listing..."
# header on stderr, so it doesn't pollute the grep on stdout.
count=$(ssh "$HOST" 'sudo apt update >/dev/null 2>&1; apt list --upgradable 2>/dev/null | grep -c "/" || true')

if [ "$count" -eq 0 ]; then
  echo ">> $HOST: already up to date, nothing to upgrade."
  exit 0
fi

echo ">> $HOST: $count package(s) can be upgraded:"
ssh "$HOST" 'apt list --upgradable 2>/dev/null | grep "/" || true'

# upgrade needs a password. Prompt once; -s keeps it off the screen.
read -rsp "sudo password for $HOST: " SUDO_PASS
echo

# Pipe the password to sudo -S over ssh stdin. -p "" suppresses the prompt so
# it isn't mixed into apt's output.
printf '%s\n' "$SUDO_PASS" | ssh "$HOST" \
  'sudo -S -p "" bash -c "DEBIAN_FRONTEND=noninteractive apt upgrade -y"'

echo ">> $HOST: upgrade complete."
