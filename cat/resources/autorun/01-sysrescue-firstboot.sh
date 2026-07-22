#!/bin/bash
# SystemRescue Firstboot Script -- Fully enables SSH with SSOT credentials
set -euo pipefail

echo "[MiOS SystemRescue Firstboot] Setting up SSH and SSOT credentials..."

# 1. Enable root login & password authentication in sshd_config
mkdir -p /etc/ssh/sshd_config.d
cat <<'EOF' > /etc/ssh/sshd_config.d/10-mios-ssh.conf
PermitRootLogin yes
PasswordAuthentication yes
X11Forwarding yes
EOF

# 2. Set SSOT root & mios user passwords
echo "root:mios" | chpasswd
if ! id "mios" &>/dev/null; then
    useradd -m -g wheel -s /bin/bash mios 2>/dev/null || true
fi
echo "mios:mios" | chpasswd

# 3. Enable and start sshd service
systemctl enable --now sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || true

echo "[MiOS SystemRescue Firstboot] SSH fully enabled. User 'mios' and 'root' ready with SSOT credentials."
