# agk Technical Assessment — Project Overview

  
**Task**: Production-Grade Kubernetes Cluster on KVM with Persistent Storage  
**Status**: All 7 Phases Complete

---

## What This Project Does

A fully documented, Infrastructure-as-Code Kubernetes platform built on KVM virtual
machines, running a 3-tier BMI Health Tracker application, with monitoring, security
hardening, operational runbooks, and a CI/CD pipeline.

Every decision is justified with a **WHY** (design rationale) and a **HOW** (exact
commands) to meet the assessment requirement: *"justify your decisions."*

---

## Architecture at a Glance

```
┌──────────────────────────────────────────────────────────────────────────────┐
│                         KVM Hypervisor (physical host)                       │
│          Terraform · Docker · GitHub Actions Self-Hosted Runner              │
│                                                                              │
│  ┌─────────────────────── Management Network 192.168.1.0/24 ──────────────┐ │
│  │                                                                         │ │
│  │   cp-01 .10  ┐                                                         │ │
│  │   Control    │  Kubernetes v1.32 cluster                               │ │
│  │   Plane      ├─ Cilium eBPF CNI  pod net 10.244.0.0/16                │ │
│  │              │  NFS StorageClass  nfs-client (default)                 │ │
│  │   w-01 .20  ─┤  Kong API Gateway  NodePort :30080                      │ │
│  │   Worker 1   │  BMI Tracker app   namespace: production                │ │
│  │              │                                                          │ │
│  │   w-02 .30  ─┘                                                         │ │
│  │   Worker 2                                                              │ │
│  │                                                                         │ │
│  │   nfs-01 .40 — NFS export /nfs/kubernetes (50 GB) → PVC provisioner   │ │
│  │   lb-01  .50 — HAProxy :80 → Kong NodePort :30080 on w-01 / w-02      │ │
│  │   db-01  .60 — PostgreSQL 17 standalone (Phase 6 failover target)      │ │
│  │                                                                         │ │
│  └─────────────────────────────────────────────────────────────────────────┘ │
│  Storage Network 192.168.2.0/24 — NFS I/O isolated from management traffic  │
│  External Network 192.168.100.0/24 — lb-01 ingress face                     │
└──────────────────────────────────────────────────────────────────────────────┘

User → lb-01:80 → HAProxy → Kong NodePort:30080
     → /api → backend-service:3000 → postgres StatefulSet (PVC on nfs-01)
     → /    → frontend-service:80  → nginx (React SPA)
```

---

## Phase Summary

| Phase | Title | Status | Location |
|-------|-------|--------|----------|
| 1 | KVM Infrastructure | ✅ Complete | `phase1-kvm-infrastructure/` |
| 2 | Kubernetes Cluster | ✅ Complete (manual) | `phase2-kubernetes-cluster/` |
| 3 | Application Deployment | ✅ Complete | `phase3-application-deployment/` |
| 4 | Monitoring & Logging | ✅ Complete | `phase4-monitoring-logging/` |
| 5 | Security Hardening | ✅ Complete | `phase5-security-hardening/` |
| 6 | Operations Runbooks | ✅ Complete | `phase6-runbooks/` |
| 7 | CI/CD Pipeline | ✅ Complete | `phase7-cicd/` |

---

## Phase 1 — KVM Infrastructure

**What**: Terraform IaC provisions 6 KVM virtual machines across 3 isolated networks.  
**Why**: Cloud-init automates all OS-level setup (repos, containerd, kubeadm) so the
cluster is reproducible from a single `terraform apply`.

### Virtual Machines

| VM | Role | CPU | RAM | Root | Data | Mgmt IP | Storage IP | External IP |
|----|------|-----|-----|------|------|---------|------------|-------------|
| cp-01 | Control Plane | 4 | 4 GB | 20 GB | — | 192.168.1.10 | 192.168.2.10 | — |
| w-01 | Worker | 4 | 4 GB | 20 GB | — | 192.168.1.20 | 192.168.2.20 | — |
| w-02 | Worker | 4 | 4 GB | 20 GB | — | 192.168.1.30 | 192.168.2.30 | — |
| nfs-01 | NFS Storage | 2 | 2 GB | 20 GB | 50 GB | 192.168.1.40 | 192.168.2.40 | — |
| lb-01 | Load Balancer | 2 | 1 GB | 20 GB | — | 192.168.1.50 | — | 192.168.100.10 |
| db-01 | PostgreSQL 17 Standalone | 2 | 4 GB | 20 GB | 30 GB | 192.168.1.60 | 192.168.2.60 | — |

**Total**: 18 CPU cores · 19 GB RAM · 320 GB+ storage

### Networks

| Network | CIDR | Purpose |
|---------|------|---------|
| kube-management | 192.168.1.0/24 | Kubernetes API, SSH, application traffic |
| kube-storage | 192.168.2.0/24 | NFS I/O only — isolated from K8s control traffic |
| kube-external | 192.168.100.0/24 | Ingress traffic to lb-01 |

### Key Files

```
phase1-kvm-infrastructure/
├── terraform/
│   ├── main.tf          # Provider (dmacvicar/libvirt ~> 0.8.1), VM configs
│   ├── vms.tf           # VM resources, dynamic disks, cloud-init attachment
│   ├── networks.tf      # 3 KVM bridge networks
│   ├── variables.tf     # Input variables
│   └── outputs.tf       # VM IPs, network names
├── cloud-init/
│   ├── control-plane.yaml  # Adds Docker + K8s v1.32 repos; installs containerd.io,
│   │                       # kubeadm, kubelet, kubectl; SystemdCgroup=true
│   ├── worker.yaml         # Identical to control-plane (no init commands)
│   ├── storage.yaml        # Formats /dev/vdb → XFS → mounts /nfs/kubernetes
│   ├── load-balancer.yaml  # HAProxy with Kong NodePort backend pre-configured
│   ├── database.yaml       # PostgreSQL 17; /dev/vdb for data dir; init-db.sh
│   └── base.yaml           # Shared baseline
└── scripts/
    ├── deploy-phase1.sh    # Single-command deployment
    └── cleanup-phase1.sh   # Full teardown
```

**Deploy**: `sudo bash phase1-kvm-infrastructure/scripts/deploy-phase1.sh`

---

## Phase 2 — Kubernetes Cluster (Manual)

**What**: Step-by-step guide to bootstrap a 3-node Kubernetes v1.32 cluster.  
**Why manual**: The assessment requires demonstrating understanding of each component.
`kubeadm` is chosen as the CNCF-endorsed production bootstrapping tool.

### Tasks

| Task | What | Key Decision |
|------|------|-------------|
| 2.1 | Initialise control plane | Cilium CNI + kube-proxy replacement (eBPF) |
| 2.2 | Join worker nodes | Node labels for workload affinity |
| 2.3 | Persistent storage | NFS subdir provisioner → `nfs-client` StorageClass |
| 2.4 | Network security | Default-deny NetworkPolicies + ResourceQuota + LimitRange + PDB |
| 2.5 | Metrics Server | Required for HPA (Phase 3); `--kubelet-insecure-tls` for bare-metal |

### CNI Decision — Cilium over Calico

Cilium is chosen for eBPF-native L3–L7 NetworkPolicy enforcement and full kube-proxy
replacement. Ubuntu 24.04 ships kernel 6.x — Cilium's eBPF maps are stable at this
kernel version, eliminating iptables rule chains that would accumulate at scale.

**File**: `phase2-kubernetes-cluster/README.md` (single authoritative file — no
fragmented sub-documents)

---

## Phase 3 — Application Deployment

**What**: Containerised 3-tier BMI Health Tracker deployed to Kubernetes.  
**Application**: React (Vite) frontend · Node.js Express backend · PostgreSQL 17 database

### Technology Stack

| Tier | Image | Version | Why |
|------|-------|---------|-----|
| Frontend | `nginx:1.27-alpine` + `node:22-alpine` (builder) | 22 LTS / 1.27 | Multi-stage build; final image ~25 MB with no Node runtime |
| Backend | `node:22-alpine` | 22 LTS | Non-root `appuser`; production deps only |
| Database | `postgres:17-alpine` | 17.x | Sep 2024 release; faster vacuum, improved logical replication |

### Kubernetes Resources

| Manifest | Resource | Purpose |
|----------|----------|---------|
| `00-namespace.yaml` | Namespace | `production` — all app workloads isolated here |
| `01-configmap.yaml` | ConfigMap | Non-sensitive config: DB host/port/name, NODE_ENV |
| `02-secret.yaml` | Secret | DB credentials, DATABASE_URL |
| `03-database.yaml` | StatefulSet + headless Service + PVC | Stable pod identity; NFS PVC 10 Gi |
| `04-backend.yaml` | Deployment + ClusterIP Service | RollingUpdate, `maxUnavailable:0`; initContainer waits for DB |
| `05-frontend.yaml` | Deployment + ClusterIP Service + HPA | 2–5 replicas, 70% CPU threshold |
| `06-kong.yaml` | NodePort Service patch | Exposes Kong proxy on :30080 / :30443 |
| `07-kong-routes.yaml` | IngressClass + 2 × Ingress + KongPlugin | `/api`→backend, `/`→frontend; rate-limit 100 req/min |

### Kong API Gateway

- **Version**: KIC v3.2.0, DB-less mode
- **Why Kong**: Built-in rate limiting, request transformation, auth plugins
  out-of-the-box. DB-less mode eliminates a stateful Kong dependency.
- **Installation**: Manual — `kubectl apply` of downloaded manifest (no Helm)
- **Exposure**: HAProxy on lb-01 → Kong NodePort :30080

---

## Phase 4 — Monitoring, Logging & Backup

**What**: Prometheus + Grafana (metrics) · Loki + Promtail (logs) · pg_dump CronJob (backup)  
**Namespace**: `monitoring`

### Component Versions

| Component | Image | Version |
|-----------|-------|---------|
| Prometheus | `prom/prometheus` | v2.53.1 |
| Node Exporter | `prom/node-exporter` | v1.8.2 |
| Grafana | `grafana/grafana` | 11.2.0 |
| Loki | `grafana/loki` | 3.1.0 |
| Promtail | `grafana/promtail` | 3.1.0 |

### Access

| Service | NodePort | Credentials |
|---------|----------|-------------|
| Grafana UI | `:30030` | admin / agk@2026! |
| Prometheus UI | `:30090` | None (internal only) |

### Key Design Choices

- **Prometheus pull model**: Kubernetes SD automatically discovers new pods/nodes
- **Loki single-binary**: No distributed microservices overhead for this scale
- **Node Exporter DaemonSet**: Guarantees one exporter per node including future nodes
- **pg_dump CronJob**: Daily at 02:00 UTC → NFS PVC `pg-backup-storage` (20 Gi)

---

## Phase 5 — Security Hardening

**What**: 5-layer defence-in-depth applied to the production namespace.

### Security Layers

| Layer | Mechanism | What it blocks |
|-------|-----------|----------------|
| 1 | **Pod Security Admission** (`restricted` profile) | Root containers, hostPath mounts, privilege escalation |
| 2 | **Dedicated ServiceAccounts** (`automountServiceAccountToken: false`) | Pods carrying API server credentials they don't need |
| 3 | **RBAC** (least-privilege roles per tier) | Backend SA reads only `bmi-secrets`; frontend/postgres SAs have zero RBAC |
| 4 | **Zero-Trust NetworkPolicies** (default-deny ingress + egress) | Any pod-to-pod path not explicitly named |
| 5 | **Non-root users** (already in Phase 3 Dockerfiles) | Container escape → root-on-host |

### Why PSA over OPA Gatekeeper

PSA is built into Kubernetes 1.25+ — no extra CRDs or webhook operator to maintain.
Three modes (`warn`, `audit`, `enforce`) allow incremental rollout without breaking
workloads. OPA Gatekeeper adds flexibility for custom policies but is over-engineered
for this assessment's security requirements.

---

## Phase 6 — Operations Runbooks

**What**: 8 step-by-step runbooks for day-2 operations.

| Runbook | Scenario | Time |
|---------|----------|------|
| 6.1 | Add a worker node | 15 min |
| 6.2 | Remove a worker node | 20 min |
| 6.3 | Rolling application update | 10 min |
| 6.4 | Database restore from pg_dump backup | 20 min |
| 6.5 | Emergency failover to db-01 VM | 30 min |
| 6.6 | Cluster node failure recovery | 30 min |
| 6.7 | Certificate renewal | 15 min |
| 6.8 | Scale frontend manually | 2 min |

**db-01** (192.168.1.60) is the Phase 6 failover target — a standalone PostgreSQL 17
VM provisioned in Phase 1 specifically for Runbook 6.5. Its dedicated 30 GB data disk
is separate from the OS disk to simplify snapshot-based backup.

---

## Phase 7 — CI/CD Pipeline

**What**: GitHub Actions pipeline — build, test, transfer images, rolling deploy.  
**Runner**: Self-hosted on the KVM hypervisor (direct route to 192.168.1.x).

### Why Self-Hosted Runner

GitHub's cloud-hosted runners run in GitHub's infrastructure and have no route to
the private 192.168.1.0/24 management network. The self-hosted runner is a single
lightweight binary installed on the hypervisor — no new VM, no VPN, no port
forwarding. It shares the management network natively.

### Pipeline Stages

```
git push main
     │
     ▼
Job 1: build (self-hosted runner on hypervisor)
  docker build → bmi-health/frontend:<SHA>
  docker build → bmi-health/backend:<SHA>
  docker build → bmi-health/database:<SHA>
  node -e calculateMetrics() sanity test
  docker save | gzip → upload artifacts
     │
     ▼
Job 2: transfer
  scp → 192.168.1.10 / .20 / .30
  ctr images import on each node
     │
     ▼
Job 3: deploy (production environment — requires approval)
  kubectl apply manifests/03..05 (SHA-tagged images)
  kubectl rollout status --timeout=180s
  port-forward health check
  on failure: kubectl rollout undo (automatic)
```

### GitHub Secrets Required

| Secret | Value |
|--------|-------|
| `SSH_PRIVATE_KEY` | Contents of `phase1-kvm-infrastructure/.ssh/id_rsa` |
| `KUBE_CONFIG` | base64-encoded kubeconfig from cp-01 (server = 192.168.1.10) |

Node IPs are hardcoded in the workflow `env:` block — not sensitive, not secrets.

---

## Repository Structure

```
PROJECT/
├── README.md                            ← This file
│
├── phase1-kvm-infrastructure/
│   ├── README.md                        # Infrastructure guide + topology diagram
│   ├── PHASE1_SUMMARY.md
│   ├── terraform/
│   │   ├── main.tf                      # dmacvicar/libvirt ~> 0.8.1 · TF >= 1.9
│   │   ├── vms.tf                       # VM resources + dynamic disks
│   │   ├── networks.tf
│   │   ├── variables.tf
│   │   └── outputs.tf
│   ├── cloud-init/
│   │   ├── control-plane.yaml           # containerd.io + kubeadm v1.32 via runcmd
│   │   ├── worker.yaml
│   │   ├── storage.yaml                 # XFS /dev/vdb → /nfs/kubernetes
│   │   ├── load-balancer.yaml           # HAProxy → Kong :30080 pre-wired
│   │   └── database.yaml               # PostgreSQL 17 + 30 GB data disk
│   └── scripts/
│       ├── deploy-phase1.sh
│       └── cleanup-phase1.sh
│
├── phase2-kubernetes-cluster/
│   └── README.md                        # Single file: Tasks 2.1–2.5 (WHY + HOW)
│
├── phase3-application-deployment/
│   ├── README.md                        # Tasks 3.1–3.4 (WHY + HOW)
│   ├── frontend/
│   │   ├── Dockerfile                   # node:22-alpine builder → nginx:1.27-alpine
│   │   ├── nginx.conf                   # SPA fallback + gzip + /health probe
│   │   └── src/                         # React + Vite source
│   ├── backend/
│   │   ├── Dockerfile                   # node:22-alpine, non-root appuser
│   │   └── src/                         # Node.js Express API
│   ├── database/
│   │   ├── Dockerfile                   # postgres:17-alpine
│   │   └── postgresql-custom.conf
│   └── manifests/
│       ├── 00-namespace.yaml
│       ├── 01-configmap.yaml
│       ├── 02-secret.yaml
│       ├── 03-database.yaml             # StatefulSet + PVC 10 Gi (nfs-client)
│       ├── 04-backend.yaml              # Deployment + initContainer busybox:1.37
│       ├── 05-frontend.yaml             # Deployment + HPA (2–5 replicas)
│       ├── 06-kong.yaml                 # Kong proxy NodePort :30080 / :30443
│       └── 07-kong-routes.yaml          # IngressClass + Ingress × 2 + RateLimit
│
├── phase4-monitoring-logging/
│   ├── README.md                        # Tasks 4.1–4.3 (WHY + HOW)
│   └── manifests/
│       ├── 00-namespace.yaml
│       ├── 01-rbac.yaml
│       ├── 02-prometheus.yaml           # prom/prometheus:v2.53.1
│       ├── 03-node-exporter.yaml        # prom/node-exporter:v1.8.2
│       ├── 04-grafana.yaml              # grafana/grafana:11.2.0
│       ├── 05-loki.yaml                 # grafana/loki:3.1.0
│       ├── 06-promtail.yaml             # grafana/promtail:3.1.0
│       └── 07-pg-dump-cronjob.yaml      # Daily 02:00 UTC → NFS PVC 20 Gi
│
├── phase5-security-hardening/
│   ├── README.md                        # Tasks 5.1–5.5 (WHY + HOW)
│   └── manifests/
│       ├── 01-namespace-psa.yaml        # PSA restricted on production namespace
│       ├── 02-serviceaccounts.yaml      # Per-tier SAs, automount disabled
│       ├── 03-rbac.yaml                 # Least-privilege roles
│       └── 04-network-policies.yaml     # Default-deny + named allow rules
│
├── phase6-runbooks/
│   └── README.md                        # 8 operational runbooks
│
└── phase7-cicd/
    ├── README.md                        # Tasks 7.1–7.4 (WHY + HOW)
    └── .github/
        └── workflows/
            └── build-and-deploy.yml     # 3-stage pipeline: build → transfer → deploy
```

---

## Technology Versions (as deployed)

| Component | Version | Notes |
|-----------|---------|-------|
| Ubuntu | 24.04 LTS (Noble) | KVM guest OS |
| Terraform | ≥ 1.9 | IaC |
| libvirt provider | ~> 0.8.1 | `dmacvicar/libvirt` |
| Kubernetes | v1.32.x | kubeadm bootstrap |
| containerd | (latest from Docker repo) | `containerd.io` package |
| Cilium CNI | v1.16.x | eBPF, kube-proxy replacement |
| NFS Provisioner | v4.0.2 | `nfs-subdir-external-provisioner` |
| Kong KIC | v3.2.0 | DB-less mode, manual install |
| Node.js | 22 LTS | Frontend builder + backend runtime |
| nginx | 1.27-alpine | Frontend server |
| PostgreSQL | 17-alpine | Database (in-cluster StatefulSet) |
| PostgreSQL | 17 (Ubuntu pkg) | db-01 standalone VM |
| busybox | 1.37 | initContainer (pinned) |
| Prometheus | v2.53.1 | Metrics collection |
| Node Exporter | v1.8.2 | OS-level metrics |
| Grafana | 11.2.0 | Dashboards |
| Loki | 3.1.0 | Log aggregation |
| Promtail | 3.1.0 | Log shipping agent |
| GitHub Actions Runner | 2.316.0 | Self-hosted on hypervisor |

---

## Key Design Clarifications

### Why a dedicated db-01 VM alongside the in-cluster PostgreSQL StatefulSet?

Two separate PostgreSQL instances serve different purposes:

| | In-cluster StatefulSet (`postgres-0`) | db-01 VM (192.168.1.60) |
|---|---|---|
| **Purpose** | Primary database for the running application | Disaster-recovery target |
| **Storage** | NFS PVC 10 Gi via nfs-subdir provisioner | Dedicated 30 GB disk (ext4, separate from OS) |
| **Lifecycle** | Tied to the Kubernetes cluster | Independent — survives cluster failure |
| **Used by** | Phase 3 application | Phase 6 Runbook 6.5 (emergency failover) |

If the Kubernetes cluster fails entirely, the DBA can point the application at
`192.168.1.60:5432` by updating the `bmi-secrets` Secret with the db-01 connection
string and restarting the backend Deployment.

### Why HAProxy on lb-01 instead of a cloud LoadBalancer?

This is a bare-metal KVM cluster with no cloud provider. There is no external load
balancer controller to provision a `EXTERNAL-IP` for a Kubernetes `LoadBalancer`
Service. HAProxy on lb-01 fills this role — it provides a stable external IP
(`192.168.100.10:80`) and round-robins HTTP traffic to Kong's NodePort
(`:30080`) on both worker nodes. This is equivalent to what a cloud load balancer
would do in a managed Kubernetes service.

### Why images are transferred via `docker save | scp | ctr import` rather than a registry?

The cluster has no external internet access from within the pod network, and setting
up a private registry (Harbor, Docker Registry) would add a Phase 1 dependency that
is out of scope. The `docker save → gzip → scp → ctr images import` pipeline is a
standard bare-metal workflow and is automated by the Phase 7 CI/CD pipeline.

### Why cloud-init installs containerd.io and kubeadm in `runcmd:` rather than `packages:`?

The `packages:` directive in cloud-init runs `apt-get install` against whatever
repositories are configured at boot time. `containerd.io` (Docker's package) and
`kubeadm/kubelet/kubectl` (Kubernetes project packages) require custom apt
repositories that must be added first. Moving their installation to `runcmd:` allows
the cloud-init script to add the repository GPG keys and source lists before the
`apt-get install` call — this is the correct ordering and avoids a "package not found"
failure that the original design would have hit.

### Why `routes:` instead of `gateway4:` in Netplan?

Ubuntu 24.04 (Noble) deprecates the `gateway4:` key in Netplan configuration. Using
it produces a deprecation warning and is scheduled for removal in a future release.
The correct replacement is a `routes:` block with `to: default` and `via: <gateway>`.
All cloud-init files in this project use the new syntax.

### Why Cilium's `kubeProxyReplacement=true`?

Running kube-proxy and Cilium simultaneously wastes resources — kube-proxy builds
iptables chains that Cilium duplicates in eBPF. Setting `kubeProxyReplacement=true`
removes kube-proxy entirely and lets Cilium handle all service load balancing through
its eBPF maps. On Ubuntu 24.04 with kernel 6.x, Cilium's eBPF dataplane is fully
stable and provides measurably lower latency for east-west service traffic.

### Why the GitHub Actions runner is self-hosted and not cloud-hosted?

GitHub's cloud-hosted runners (`ubuntu-22.04`) run in GitHub's data centres. They
have no network route to the `192.168.1.0/24` management network inside the KVM
hypervisor. A self-hosted runner is a single lightweight process installed on the
hypervisor itself — it shares the management network directly and can SSH to all
cluster nodes without any VPN or firewall rule changes.

---

## Security Note on Credentials

> **Placeholder credentials**: `phase3-application-deployment/manifests/02-secret.yaml`
> and the Phase 6 runbooks use a demonstration password (`StrongP@ssw0rd!`). In a real
> deployment, replace this with a secrets manager — HashiCorp Vault, the Kubernetes
> External Secrets Operator, or GitHub Actions Secrets for the CI/CD path. The password
> is present in the repository's commit history and **must be rotated** before any
> public or production use of this codebase.

---

## Public Access When the Hypervisor Is an EC2 Instance

The architecture above assumes the KVM hypervisor is bare-metal on a private
network, with `lb-01` (192.168.100.10) reachable directly. When the
hypervisor is itself a cloud VM (e.g. an EC2 instance used to demo this
project), `lb-01` is only reachable from inside that instance — none of the
`192.168.x.x` addresses are routable from the internet. Reaching the app from
outside requires one more hop: port-forwarding on the hypervisor's public
interface into the KVM `kube-external` bridge.

### Why this is a separate step, not part of Phase 1

This is a property of *where the hypervisor happens to be running*, not of
the cluster design — a bare-metal hypervisor on a LAN wouldn't need it, and
baking cloud-specific NAT rules into `deploy-phase1.sh` would couple
infrastructure-as-code that's meant to be environment-agnostic to one
specific host type. It's applied manually, once, after Phase 3.

### Setup (run on the hypervisor, i.e. the EC2 instance)

```bash
# Find the hypervisor's public-facing NIC (not a virbr* bridge)
PUB_IF=$(ip -o -4 addr show | awk '!/virbr|docker0|lo/{print $2; exit}')

# DNAT: hypervisor public IP:80/443 → lb-01:80/443
sudo iptables -t nat -A PREROUTING -i "$PUB_IF" -p tcp --dport 80  -j DNAT --to-destination 192.168.100.10:80
sudo iptables -t nat -A PREROUTING -i "$PUB_IF" -p tcp --dport 443 -j DNAT --to-destination 192.168.100.10:443

# Explicit ACCEPT for the new (not yet established) DNAT'd connections —
# the existing FORWARD rules from deploy-phase1.sh only ACCEPT
# RELATED,ESTABLISHED traffic back *into* kube-external, not new sessions.
sudo iptables -I FORWARD 1 -p tcp -d 192.168.100.10 --dport 80  -j ACCEPT
sudo iptables -I FORWARD 1 -p tcp -d 192.168.100.10 --dport 443 -j ACCEPT
```

These rules are **not persisted across reboots** by default — install
`iptables-persistent` (`netfilter-persistent save`) if the hypervisor may
restart.

### Also required: open the port in the cloud firewall

The above only forwards traffic *inside* the instance. The cloud provider's
firewall (AWS Security Group / GCP firewall rule / Azure NSG) must separately
allow inbound TCP 80 (and 443 if used) to the instance — this cannot be done
from inside the instance and has no relationship to anything in this repo;
configure it via the provider's console or CLI with your own credentials.

### Result

```
Browser → http://<hypervisor-public-ip>/ → iptables DNAT → lb-01:80 (HAProxy)
        → Kong NodePort :30080 on w-01/w-02 → frontend/backend Services
```

Verify:
```bash
curl -s http://<hypervisor-public-ip>/ | grep -i title
curl -s http://<hypervisor-public-ip>/api/measurements
```

> This exposes the demo application over plain HTTP with no TLS and no
> authentication in front of it beyond Kong's rate-limiting plugin (Phase 3).
> Treat any URL set up this way as a temporary demo endpoint, not a
> production exposure — tear down the DNAT rules (`iptables -t nat -D ...`)
> and close the security-group port when the demo is done.

---

## Execution Order

```
Step 1 — Install self-hosted runner on hypervisor (Phase 7 prerequisite)
Step 2 — Deploy VMs:  sudo bash phase1-kvm-infrastructure/scripts/deploy-phase1.sh
Step 3 — Build cluster: follow phase2-kubernetes-cluster/README.md (Tasks 2.1–2.5)
Step 4 — Deploy app:  follow phase3-application-deployment/README.md (Tasks 3.1–3.4)
Step 5 — Monitoring:  follow phase4-monitoring-logging/README.md (Tasks 4.1–4.3)
Step 6 — Harden:      follow phase5-security-hardening/README.md (Tasks 5.1–5.5)
Step 7 — Push to GitHub → pipeline auto-deploys on every commit to main
```

**Estimated total time**: 3–4 hours (infrastructure 15 min · cluster 60 min ·
app 30 min · monitoring 30 min · hardening 20 min · CI/CD setup 15 min)

---

**Project**: agk Software Limited Technical Assessment 
**Assessment**: Production-Grade Kubernetes Cluster on KVM with Persistent Storage
