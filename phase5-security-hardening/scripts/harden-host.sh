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

# WARNING: The networks below match the deployment in NETWORK_TOPOLOGY.md.
# If your KVM bridge IP ranges differ, update these values before running.
#
# This script runs on every node (control plane, workers, nfs-01, lb-01,
# db-01) with one shared rule set — a rule for a port nothing on that node
# listens on is a harmless no-op, so it's simpler to allow broadly here than
# to fork the rule set per role. But every rule below IS required on at
# least one node, confirmed against a live cluster (`ss -tlnp` / `ss -ulnp`)
# rather than assumed from Kubernetes docs alone:
#   - 10250/tcp, 4240/tcp, 8472/udp were all observed LISTENing on cp-01 and
#     the workers. Without them, kubectl exec/logs/metrics-server (10250),
#     Cilium's cross-node health checks (4240), and the VXLAN pod-network
#     overlay itself (8472/udp) all break — the last one takes down
#     cross-node pod networking entirely.
#   - 2379-2380/tcp (etcd) is observed listening on cp-01's management IP,
#     not just loopback; kept open for correctness / future multi-CP.
#   - 30000-32767/tcp (NodePort range) is how lb-01's HAProxy reaches Kong
#     on w-01/w-02:30080 (and Grafana/Prometheus in Phase 4). Without it,
#     the app becomes unreachable through the load balancer.
#   - 5432/tcp is required on db-01 for Runbook 6.5 (emergency failover) —
#     the backend Deployment connects to postgresql://...@192.168.1.60:5432
#     directly, and that traffic is masqueraded to the pod's node IP
#     (192.168.1.0/24) by Cilium before it reaches db-01.
# (10259/10257 — scheduler/controller-manager — are NOT listed: they were
# observed bound to 127.0.0.1 only, so no cross-node rule is needed.)

ufw --force reset
ufw default deny incoming
ufw default allow outgoing

# kube-management network (192.168.1.0/24) — allow SSH from management network
ufw allow from 192.168.1.0/24 to any port 22

# kube-management network (192.168.1.0/24) — allow Kubernetes API from management network
ufw allow from 192.168.1.0/24 to any port 6443

# kubelet API — control plane -> node (exec/logs/metrics-server) on every node
ufw allow from 192.168.1.0/24 to any port 10250

# etcd client + peer (cp-01; kept open cluster-wide for simplicity/future multi-CP)
ufw allow from 192.168.1.0/24 to any port 2379:2380 proto tcp

# Cilium cross-node health checks
ufw allow from 192.168.1.0/24 to any port 4240

# Cilium VXLAN pod-network overlay — required for cross-node pod-to-pod traffic
ufw allow from 192.168.1.0/24 to any port 8472 proto udp

# NodePort range — lb-01 (HAProxy) -> Kong on w-01/w-02:30080/30443,
# and Grafana/Prometheus NodePorts (Phase 4)
ufw allow from 192.168.1.0/24 to any port 30000:32767 proto tcp

# db-01 PostgreSQL — required for Runbook 6.5 emergency failover
ufw allow from 192.168.1.0/24 to any port 5432

# kube-storage network (192.168.2.0/24) — allow NFS from storage network
ufw allow from 192.168.2.0/24 to any port 2049

# kube-external network (192.168.100.0/24) — allow HTTP from external network
ufw allow from 192.168.100.0/24 to any port 80

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
