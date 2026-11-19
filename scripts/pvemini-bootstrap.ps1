# One-time bootstrap for the mini PC (pvemini, 192.168.0.3). Asks for its root password once.
#  1. Installs pve_ed25519.pub for root, so the pvemini.root alias logs in without a password.
#  2. Switches APT off the subscription-only enterprise repos (401 without a paid key)
#     onto pve-no-subscription, then runs apt update.
# Same result as ansible/roles/proxmox/tasks/repos.yml; this just gets a fresh box there.
$pub = (Get-Content "$env:USERPROFILE\.ssh\pve_ed25519.pub" -Raw).Trim()
$script = @'
set -e
mkdir -p /root/.ssh
grep -qxF "__PUB__" /root/.ssh/authorized_keys 2>/dev/null || echo "__PUB__" >> /root/.ssh/authorized_keys
echo "== root key installed"
rm -f /etc/apt/sources.list.d/pve-enterprise.sources /etc/apt/sources.list.d/ceph.sources \
      /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/ceph.list
. /etc/os-release
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $VERSION_CODENAME
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
echo "== repos now:"; ls /etc/apt/sources.list.d/
apt update
'@
$script = $script.Replace("__PUB__", $pub).Replace("`r`n", "`n")
$script | ssh -o StrictHostKeyChecking=accept-new root@192.168.0.3 "sh -s"
