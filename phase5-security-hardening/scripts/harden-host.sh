#!/bin/bash
# ── Host Hardening Script ──────────────────────────────────────────────────
# Run as root on each KVM host node. Tested on Ubuntu 22.04 LTS.
#
# Usage:
#   sudo bash harden-host.sh
#
# What it does:
#   1. Harden SSH configuration
#   2. Apply UFW host firewall rules
#   3. Set kernel sysctl hardening parameters
#   4. Disable unnecessary services
# ──────────────────────────────────────────────────────────────────────────────

set -euo pipefail

echo "=== Starting host hardening ==="

# ── 1. SSH Hardening ────────────────────────────────────────────────────────
echo "[1/4] Hardening SSH configuration..."
SSHD_CONFIG=/etc/ssh/sshd_config

# Backup the original
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"

cat > "$SSHD_CONFIG" <<'SSHEOF'
# Managed by harden-host.sh — manual edits will be overwritten
Port 22
Protocol 2
PasswordAuthentication no
PermitRootLogin no
PubkeyAuthentication yes
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
ChallengeResponseAuthentication no
UsePAM yes
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
Subsystem sftp /usr/lib/openssh/sftp-server
SSHEOF

systemctl restart sshd
echo "  SSH config hardened."

# ── 2. UFW Firewall ─────────────────────────────────────────────────────────
echo "[2/4] Applying UFW firewall rules..."
ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# Management SSH — allow from private RFC 1918 ranges
ufw allow from 10.0.0.0/8 to any port 22

# Kubernetes API Server — cluster network only
ufw allow from 10.0.1.0/24 to any port 6443

# NFS — storage network only
ufw allow from 10.0.2.0/24 to any port 2049

ufw --force enable
echo "  UFW firewall enabled."

# ── 3. Kernel Sysctl Hardening ──────────────────────────────────────────────
echo "[3/4] Setting kernel sysctl parameters..."
cat > /etc/sysctl.d/99-hardening.conf <<'SYSCTLEOF'
# Kubernetes requirements
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1

# Security hardening
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
kernel.dmesg_restrict = 1
SYSCTLEOF

sysctl --system
echo "  Sysctl parameters applied."

# ── 4. Disable Unnecessary Services ─────────────────────────────────────────
echo "[4/4] Disabling unnecessary services..."
systemctl disable --now avahi-daemon cups bluetooth 2>/dev/null || true
echo "  Unnecessary services disabled."

echo "=== Host hardening complete ==="
echo "Review /etc/ssh/sshd_config and /etc/sysctl.d/99-hardening.conf for details."
