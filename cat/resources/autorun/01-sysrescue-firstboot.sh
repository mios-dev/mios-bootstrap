#!/bin/bash
# SystemRescue Firstboot Script -- Fully enables SSH with SSOT credentials & displays live IP on console
set -euo pipefail

echo "[MiOS SystemRescue Firstboot] Setting up SSH and SSOT credentials..."

# 1. Generate SSH host keys if missing
if [ ! -f /etc/ssh/ssh_host_rsa_key ]; then
    ssh-keygen -A 2>/dev/null || true
fi

# 2. Enable root login & password authentication in sshd_config
mkdir -p /etc/ssh/sshd_config.d
cat <<'EOF' > /etc/ssh/sshd_config.d/10-mios-ssh.conf
PermitRootLogin yes
PasswordAuthentication yes
X11Forwarding yes
PubkeyAuthentication yes
EOF

# 3. Set SSOT root & mios user passwords
echo "root:mios" | chpasswd
if ! id "mios" &>/dev/null; then
    useradd -m -g wheel -s /bin/bash mios 2>/dev/null || true
fi
echo "mios:mios" | chpasswd

# 4. Enable and start sshd service
systemctl enable --now sshd 2>/dev/null || systemctl restart sshd 2>/dev/null || true

# 5. Display IP address banner on tty1 and MOTD
IP_LIST=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' || echo "No IP detected yet")
BANNER="
===================================================================
  MiOS SystemRescue Live Diagnostic Environment
  SSH Service: ACTIVE (Port 22)
  Credentials: root / mios  |  mios / mios
  IP Address(es): ${IP_LIST}
===================================================================
"
echo "${BANNER}" >> /etc/issue
echo "${BANNER}" >> /etc/motd
if [ -c /dev/tty1 ]; then
    echo "${BANNER}" > /dev/tty1 || true
fi

echo "[MiOS SystemRescue Firstboot] SSH fully enabled. User 'mios' and 'root' ready with SSOT credentials."
