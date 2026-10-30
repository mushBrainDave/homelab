#!/usr/bin/env bash
#
# Report whether Docker, Frigate, or MediaMTX on the ubuntu VM have updates
# available. Read-only: nothing is pulled, upgraded, or restarted, and no sudo
# password is needed (only the passwordless `sudo apt update`).
#
#   docker    apt candidate vs installed (the actionable update -- this host
#             runs Ubuntu's docker.io package), plus upstream moby release FYI
#   frigate   registry digest of the compose tag vs the local image, whether the
#             running container is on that local image, plus latest GH release
#   mediamtx  `mediamtx --version` vs latest GH release, plus the version
#             pinned in ansible/group_vars/all.yml (drift warning)
#
# All lookups run on the ubuntu host (it has curl + jq). GitHub API calls are
# unauthenticated (60/hr), which is plenty for a by-hand check.
#
# Usage: ./check-updates.sh [host]   (defaults to ubuntu)
# Exit:  0 = everything current, 1 = at least one update available, 2 = error
set -uo pipefail

HOST="${1:-ubuntu}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# The image tag Frigate runs, and the MediaMTX version Ansible would deploy.
FRIGATE_IMAGE=$(sed -n 's/^[[:space:]]*image:[[:space:]]*\([^[:space:]]*\).*/\1/p' "$REPO_ROOT/docker/frigate/docker-compose.yml" | head -1)
MEDIAMTX_PIN=$(sed -n 's/^mediamtx_version:[[:space:]]*"\{0,1\}\([^"]*\)".*/\1/p' "$REPO_ROOT/ansible/group_vars/all.yml")

# --- remote payload: prints KEY=value lines, parsed below --------------------
read -r -d '' REMOTE <<'EOF' || true
set -u
gh_latest() { curl -fsSL -m 10 "https://api.github.com/repos/$1/releases/latest" | jq -r .tag_name; }

# docker: refresh the index (the one passwordless sudo), then ask apt.
sudo -n apt update >/dev/null 2>&1 || true
PKG=$(dpkg-query -W -f='${Package}\n' docker-ce docker.io 2>/dev/null | head -1)
echo "DOCKER_PKG=${PKG}"
echo "DOCKER_INSTALLED=$(apt-cache policy "$PKG" | awk '/Installed:/ {print $2}')"
echo "DOCKER_CANDIDATE=$(apt-cache policy "$PKG" | awk '/Candidate:/ {print $2}')"
echo "DOCKER_UPSTREAM=$(gh_latest moby/moby)"

# frigate: compare the registry's digest for the tag against the local image.
IMG="$FRIGATE_IMAGE"
REPO=${IMG#ghcr.io/}; REPO=${REPO%%:*}; TAG=${IMG##*:}
TOKEN=$(curl -fsSL -m 10 "https://ghcr.io/token?scope=repository:${REPO}:pull" | jq -r .token)
REMOTE_DIGEST=$(curl -fsSI -m 10 -H "Authorization: Bearer ${TOKEN}" \
  -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json" \
  "https://ghcr.io/v2/${REPO}/manifests/${TAG}" | awk -F': ' 'tolower($1)=="docker-content-digest" {print $2}' | tr -d '\r')
echo "FRIGATE_REMOTE_DIGEST=${REMOTE_DIGEST}"
echo "FRIGATE_LOCAL_DIGESTS=$(docker image inspect --format '{{join .RepoDigests " "}}' "$IMG" 2>/dev/null)"
echo "FRIGATE_LOCAL_ID=$(docker image inspect --format '{{.Id}}' "$IMG" 2>/dev/null)"
echo "FRIGATE_RUNNING_ID=$(docker inspect --format '{{.Image}}' frigate 2>/dev/null)"
echo "FRIGATE_VERSION=$(curl -fsS -m 5 http://localhost:5000/api/version 2>/dev/null)"
echo "FRIGATE_UPSTREAM=$(gh_latest blakeblackshear/frigate)"

# mediamtx: native binary.
echo "MEDIAMTX_VERSION=$(/usr/local/bin/mediamtx --version 2>/dev/null)"
echo "MEDIAMTX_UPSTREAM=$(gh_latest bluenviron/mediamtx)"
EOF

# base64 so quoting survives ssh intact; the image name is passed as an env var.
ENC=$(printf '%s' "$REMOTE" | base64 | tr -d '\n')
if ! OUT=$(ssh -o ConnectTimeout=10 "$HOST" \
    "echo $ENC | base64 --decode | FRIGATE_IMAGE='$FRIGATE_IMAGE' bash" 2>/dev/null); then
  echo ">> $HOST: ssh failed" >&2
  exit 2
fi
get() { sed -n "s/^$1=//p" <<<"$OUT"; }
strip_v() { local v=${1#docker-}; v=${v#v}; echo "${v%%-*}"; }   # v0.18.0-77a66e7 -> 0.18.0

updates=0
flag()  { printf '  %-9s \e[33mUPDATE\e[0m  %s\n' "$1" "$2"; updates=1; }
ok()    { printf '  %-9s \e[32mok\e[0m      %s\n' "$1" "$2"; }
warn()  { printf '  %-9s \e[31m??\e[0m      %s\n' "$1" "$2"; }
note()  { printf '  %-9s         %s\n' "" "$1"; }

echo ">> $HOST: checking docker, frigate, mediamtx ..."
echo

# --- docker ------------------------------------------------------------------
pkg=$(get DOCKER_PKG); inst=$(get DOCKER_INSTALLED); cand=$(get DOCKER_CANDIDATE)
if [ -z "$pkg" ]; then
  warn docker "no docker-ce / docker.io package found"
elif [ "$inst" != "$cand" ]; then
  flag docker "$pkg $inst -> $cand  (apply with update.sh / update-all.sh)"
else
  ok docker "$pkg $inst (latest in apt)"
fi
note "upstream release: $(get DOCKER_UPSTREAM)"

# --- frigate -----------------------------------------------------------------
rdig=$(get FRIGATE_REMOTE_DIGEST); ldigs=$(get FRIGATE_LOCAL_DIGESTS)
fver=$(get FRIGATE_VERSION); fup=$(get FRIGATE_UPSTREAM)
if [ -z "$rdig" ]; then
  warn frigate "couldn't read registry digest for $FRIGATE_IMAGE"
elif [[ " $ldigs " != *"@$rdig "* ]]; then
  flag frigate "new image published for $FRIGATE_IMAGE  (docker compose pull && up -d)"
else
  ok frigate "${fver:-?} — local image matches registry"
fi
run_id=$(get FRIGATE_RUNNING_ID); local_id=$(get FRIGATE_LOCAL_ID)
if [ -n "$run_id" ] && [ -n "$local_id" ] && [ "$run_id" != "$local_id" ]; then
  flag frigate "container is running an older image than the one pulled  (docker compose up -d)"
fi
[ -n "$fver" ] && [ -n "$fup" ] && [ "$(strip_v "$fver")" != "$(strip_v "$fup")" ] \
  && note "running $fver, latest GitHub release $fup (tag may not have moved yet)" \
  || note "latest GitHub release: ${fup:-?}"

# --- mediamtx ----------------------------------------------------------------
mver=$(get MEDIAMTX_VERSION); mup=$(get MEDIAMTX_UPSTREAM)
if [ -z "$mver" ] || [ -z "$mup" ]; then
  warn mediamtx "installed=${mver:-?} upstream=${mup:-?}"
elif [ "$(strip_v "$mver")" != "$(strip_v "$mup")" ]; then
  flag mediamtx "$mver -> $mup  (bump mediamtx_version, re-run the mediamtx role)"
else
  ok mediamtx "$mver (latest)"
fi
if [ -n "$mver" ] && [ "$(strip_v "$mver")" != "$MEDIAMTX_PIN" ]; then
  note "repo pins mediamtx_version $MEDIAMTX_PIN but host runs $mver — ansible would change it"
fi

echo
exit $updates
