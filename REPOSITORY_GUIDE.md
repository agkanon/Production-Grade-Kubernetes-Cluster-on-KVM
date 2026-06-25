# Repository Guide — agk Technical Assessment
## Production-Grade Kubernetes Cluster on KVM with Persistent Storage

This document explains every component of the repository: what each file does, why it was
designed that way, how the phases depend on each other, and what runs where at runtime.
Read this alongside the phase-level READMEs for step-by-step commands.

---

## Repository Layout

```
PROJECT/
├── README.md                              # Top-level overview (start here)
├── REPOSITORY_GUIDE.md                    # This file
├── phase1-kvm-infrastructure/             # Terraform + KVM hypervisor setup
│   ├── terraform/                         # Provider, VMs, networks, outputs
│   ├── cloud-init/                        # Per-role VM bootstrap configs
│   ├── scripts/                           # deploy-phase1.sh, test-ssh.sh, etc.
│   ├── docs/                              # Design decisions, network topology, plan
│   ├── README.md
│   └── PHASE1_SUMMARY.md
├── phase2-kubernetes-cluster/             # kubeadm, Cilium, NFS provisioner
│   └── README.md
├── phase3-application-deployment/         # BMI Tracker app manifests
│   ├── manifests/                         # 00-namespace → 07-kong-routes
│   ├── frontend/                          # React + Vite Dockerfile
│   ├── backend/                           # Node.js Express Dockerfile
│   ├── database/                          # PostgreSQL 17 + init SQL Dockerfile
│   └── README.md
├── phase4-monitoring-logging/             # Prometheus, Grafana, Loki, Promtail
│   ├── manifests/                         # 00-namespace → 07-pg-dump-cronjob
│   └── README.md
├── phase5-security-hardening/             # PSA, RBAC, NetworkPolicies, UFW
│   ├── manifests/                         # 01-namespace-psa → 04-network-policies
│   └── README.md
├── phase6-runbooks/                       # Operational runbooks (6.1–6.7)
│   └── README.md
└── phase7-cicd/                           # GitHub Actions pipeline
    ├── .github/workflows/build-and-deploy.yml
    └── README.md
```

---

## VM Topology

Six KVM virtual machines run on a single bare-metal hypervisor. Each VM has a
defined role and is provisioned automatically via Terraform + cloud-init.

| VM | Management IP | Storage IP | External IP | CPU | RAM | Root Disk | Extra Disk | Role |
|----|---------------|------------|-------------|-----|-----|-----------|------------|------|
| cp-01 | 192.168.1.10 | — | — | 4 | 4 GB | 20 GB | K8s control plane |
| w-01 | 192.168.1.20 | — | — | 4 | 4 GB | 20 GB | K8s worker |
| w-02 | 192.168.1.30 | — | — | 4 | 4 GB | 20 GB | K8s worker |
| nfs-01 | 192.168.1.40 | 192.168.2.40 | — | 2 | 2 GB | 20 GB | 50 GB NFS share |
| lb-01 | 192.168.1.50 | — | 192.168.100.10 | 2 | 1 GB | 20 GB | HAProxy load balancer |
| db-01 | 192.168.1.60 | — | — | 2 | 4 GB | 20 GB | 30 GB PostgreSQL 17 DR |

**Total hypervisor resources consumed**: 18 vCPU, 19 GB RAM, 170 GB storage.

---

## Network Design

Three isolated virtual networks are created by Terraform as `libvirt_network` resources.
Each maps to a Linux bridge on the hypervisor.

```
┌──────────────────────────────────────────────────────────────────┐
│  HYPERVISOR                                                      │
│                                                                  │
│  Management (virbr1) 192.168.1.0/24  ─── all 6 VMs (SSH / K8s) │
│  Storage    (virbr2) 192.168.2.0/24  ─── nfs-01 (NFS mounts)    │
│  External   (virbr3) 192.168.100.0/24─── lb-01  (HTTP/HTTPS)    │
└──────────────────────────────────────────────────────────────────┘
```

### Why Three Networks?

| Network | Purpose | Who Uses It |
|---------|---------|-------------|
| Management | SSH administration, Kubernetes API (6443), kubelet, kubeadm join | All VMs, CI/CD runner |
| Storage | NFS data transfer (port 2049) — isolated for performance and security | nfs-01 ↔ cp-01, w-01, w-02 |
| External | Public-facing HTTP(S) entry point through HAProxy | lb-01 ↔ external clients |

**Critical IP**: All Kubernetes NFS mounts and the nfs-subdir-external-provisioner
must use `192.168.2.40` (the storage NIC), not `192.168.1.40` (the management NIC).
The NFS export is restricted to `192.168.2.0/24` only — connection attempts from the
management network will be refused by `/etc/exports`.

---

## Deployment Order and Phase Dependencies

Each phase has hard prerequisites from the phase before it. Do not skip ahead.

```
Phase 1 ──► Phase 2 ──► Phase 3 ──► Phase 4
  │            │            │
  │            └──────────────────► Phase 5
  │                         │
  └─────────────────────────────► Phase 6
                            │
                            └──► Phase 7
```

| Phase | Depends On | What It Provides for Next Phases |
|-------|------------|----------------------------------|
| 1 | Bare hypervisor with KVM/QEMU/Terraform | 6 running VMs, SSH access, bridge networks |
| 2 | Phase 1 (VMs up, SSH working) | Kubernetes cluster, NFS StorageClass, kubeconfig |
| 3 | Phase 2 (cluster ready, StorageClass available) | Running application, Kong routes, PVCs provisioned |
| 4 | Phase 2 (cluster) + Phase 3 (app pods to scrape) | Prometheus metrics, Grafana dashboards, Loki logs, backup CronJob |
| 5 | Phase 2 (namespaces exist) + Phase 3 (pods deployed) | PSA labels, RBAC, NetworkPolicies applied |
| 6 | All phases deployed (runbooks reference live state) | Operational procedures |
| 7 | Phase 2 (kubectl access) + Phase 3 (manifests exist) | Automated image build and rolling deploy |

---

## Phase 1 — KVM Infrastructure

### Terraform Structure

```
terraform/
├── main.tf        # Provider config (dmacvicar/libvirt ~> 0.8.1) and cloud-init
├── networks.tf    # 3 libvirt_network resources (management, storage, external)
├── vms.tf         # 6 libvirt_domain resources with dynamic disk attachment
├── variables.tf   # vm_configs map (all VM parameters in one place)
└── outputs.tf     # Management IPs for all 6 VMs
```

`vms.tf` uses `for_each` over `var.vm_configs`, a map where each key is a VM name
(`"cp-01"`, `"w-01"`, etc.) and each value contains cpu, memory, disk, IPs, and which
cloud-init file to use. The extra disks (nfs-01: 50 GB, db-01: 30 GB) are attached via
`dynamic "disk"` blocks — only added when the `extra_disk_size` key is present in the
VM's config map.

`terraform.tfvars` is **not committed** — it is generated at runtime by `deploy-phase1.sh`
and contains the SSH public/private key pair. It is listed in `.gitignore`. If this file
is missing, run `deploy-phase1.sh` which creates the SSH keypair and generates the file
before calling `terraform apply`.

### Cloud-Init Files

Each VM role gets a dedicated cloud-init file. Terraform renders each file as a
`libvirt_cloudinit_disk` using `templatefile()`, injecting the VM's IPs before boot.

| File | VM | Key Configuration |
|------|----|------------------|
| `control-plane.yaml` | cp-01 | K8s apt repo, containerd.io, crictl, haproxy stub |
| `worker.yaml` | w-01, w-02 | K8s apt repo, containerd.io, data directory pre-created |
| `storage.yaml` | nfs-01 | nfs-kernel-server, `/nfs/kubernetes` exported to 192.168.2.0/24, dual NIC (eth0+eth1) |
| `load-balancer.yaml` | lb-01 | HAProxy 2.x, TCP health check on Kong NodePort 30080, dual NIC (eth0+eth1) |
| `database.yaml` | db-01 | PGDG apt repo, postgresql-17, `/etc/postgresql/17/` paths, 30 GB data disk mounted at `/var/lib/postgresql` |

All cloud-init files use `routes:` with `to: default / via:` for static IP configuration
(Netplan >= 0.102, Ubuntu 24.04). The deprecated `gateway4:` key is not used anywhere.

### Scripts

| Script | Purpose |
|--------|---------|
| `deploy-phase1.sh` | Generates SSH keypair → writes `terraform.tfvars` → runs `terraform apply` → verifies all VMs reachable |
| `setup-ssh.sh` | Configures `~/.ssh/config` aliases (cp-01, w-01, w-02, nfs-01, lb-01, db-01) |
| `test-ssh.sh` | Connects to each of the 6 VMs with `StrictHostKeyChecking=yes` and prints OS version |
| `cleanup-phase1.sh` | Runs `terraform destroy` and removes generated keys and tfvars |

---

## Phase 2 — Kubernetes Cluster

Bootstrapped with `kubeadm init` on cp-01, joined by w-01 and w-02 as workers.

### Key Configuration Decisions

| Decision | Value | Reason |
|----------|-------|--------|
| Pod CIDR | `10.244.0.0/16` | Cilium default IPAM range; also referenced in UFW rules for db-01 |
| Service CIDR | `10.96.0.0/12` | Kubernetes default |
| CNI | Cilium with `kubeProxyReplacement=true` | eBPF data plane: no iptables overhead, native load balancing, better observability |
| kube-proxy | **Deleted** after Cilium install | Cilium fully replaces kube-proxy; running both causes iptables/eBPF routing conflicts |
| Container runtime | containerd (from `containerd.io` Docker package) | CRI-compliant, production standard |
| Cgroup driver | `SystemdCgroup = true` in containerd config | Required for kubelet with systemd — note capital S (containerd v2 key format) |

### NFS StorageClass

The `nfs-subdir-external-provisioner` (v4.0.2) runs as a Deployment on the cluster and
dynamically provisions PVCs backed by NFS subdirectories.

```
NFS server: 192.168.2.40 (storage NIC of nfs-01)
NFS path:   /nfs/kubernetes
StorageClass: nfs-client (set as default)
```

Every PVC in the cluster that does not specify a storageClassName gets this class automatically.

---

## Phase 3 — Application Deployment

Three-tier BMI Health Tracker application deployed to the `production` namespace.

### Application Architecture

```
Internet → HAProxy (lb-01:80) → Kong KIC NodePort :30080
                                       ↓
                         ┌─────────────────────────┐
                         │  Kong routes (/api, /)  │
                         └────────────┬────────────┘
                              /       │       \
                         frontend   backend   (static: frontend)
                        (port 80)  (port 3000)
                                       │
                                  postgres StatefulSet
                                    (port 5432)
                                       │
                                  NFS PVC 10Gi
```

### Manifest Order

| File | Resource | Notes |
|------|----------|-------|
| `00-namespace.yaml` | Namespace `production` | Must exist before any other resource |
| `01-configmap.yaml` | ConfigMap `bmi-config` | `PORT=3000`, `DB_HOST=postgres-service`, `NODE_ENV=production` |
| `02-secret.yaml` | Secret `bmi-secrets` | `db-user`, `db-password`, `database-url` — applied once, guarded by CI/CD |
| `03-database.yaml` | StatefulSet `postgres` + headless Service | Custom image `bmi-health/database:1.0.0` (postgres:17-alpine + init SQL) |
| `04-backend.yaml` | Deployment `backend` (2 replicas) + ClusterIP Service | Port 3000; init container waits for postgres on 5432 |
| `05-frontend.yaml` | Deployment `frontend` (2 replicas) + ClusterIP Service + HPA | Port 80; HPA scales 2–5 at 70% CPU |
| `06-kong.yaml` | Kong Ingress Controller (KIC v3.2.0) | DB-less mode; NodePort 30080 (HTTP), 30443 (HTTPS) |
| `07-kong-routes.yaml` | KongIngress + Ingress resources | `/api` → `backend-service:3000`; `/` → `frontend-service:80` |

### Port Consistency

The backend port `3000` must be consistent in every layer:
- `01-configmap.yaml`: `PORT: "3000"`
- `04-backend.yaml`: `containerPort: 3000`, service `port: 3000`, liveness/readiness `port: 3000`
- `07-kong-routes.yaml`: backend upstream `port: 3000`
- Phase 5 NetworkPolicies: `backend-policy` ingress allows port 3000

---

## Phase 4 — Monitoring and Logging

All monitoring components deploy to the `monitoring` namespace.

### Stack Versions

| Component | Image | Version |
|-----------|-------|---------|
| Prometheus | `prom/prometheus` | v2.53.1 |
| Node Exporter | `prom/node-exporter` | v1.8.2 |
| Grafana | `grafana/grafana` | 11.2.0 |
| Loki | `grafana/loki` | 3.1.0 |
| Promtail | `grafana/promtail` | 3.1.0 |

### Key Design Notes

**Grafana credentials**: Stored in a Kubernetes Secret `grafana-admin` (namespace: `monitoring`).
The Deployment references them via `secretKeyRef` — credentials are never visible in
`kubectl get deployment -o yaml`. Default credentials: `admin / agk@2026!`.

**Promtail security context**: Promtail runs as `runAsUser: 0` (root) because it must read
`/var/log/pods/*` which is owned by root on the host. `runAsNonRoot` is NOT set — it would
contradict `runAsUser: 0` and cause Kubernetes to reject all Promtail pods immediately.
The `monitoring` namespace uses PSA `baseline` (not `restricted`) for this reason.

**pg_dump CronJob** (`07-pg-dump-cronjob.yaml`):
- Schedule: `0 2 * * *` (02:00 UTC daily)
- Image: `postgres:17-alpine` (matches the in-cluster database version)
- PVC: `pg-backup-storage` (20 Gi, ReadWriteMany, StorageClass `nfs-client`)
- ServiceAccount: `pg-backup-sa` (defined in Phase 5 `02-serviceaccounts.yaml`)
- RPO: 24 hours | RTO: 30 minutes (see Runbook 6.4 / 6.5)

---

## Phase 5 — Security Hardening

### Manifest Application Order

```
01-namespace-psa.yaml     ← Must come first (sets PSA enforcement labels)
02-serviceaccounts.yaml   ← Creates SAs; Phase 3 Deployments reference them
03-rbac.yaml              ← Roles and RoleBindings that reference the SAs above
04-network-policies.yaml  ← Zero-trust policies (default-deny + explicit allows)
```

Apply Phase 5 **after** Phase 3, because PSA `restricted` on the `production` namespace
is enforced immediately — Phase 3 manifests must already comply before Phase 5 is applied.

### Pod Security Admission

| Namespace | Level | Reason |
|-----------|-------|--------|
| `production` | `restricted` | App pods are stateless, non-root, read-only FS |
| `monitoring` | `baseline` | Promtail requires root; Node Exporter uses hostNetwork/hostPID |
| `kong` | `baseline` | KIC requires elevated capabilities |

### ServiceAccounts

Four dedicated SAs are defined in `02-serviceaccounts.yaml`, all with
`automountServiceAccountToken: false` (token is never projected into the pod unless
explicitly requested — follows least-privilege principle).

| ServiceAccount | Used By | Namespace |
|----------------|---------|-----------|
| `frontend-sa` | frontend Deployment | production |
| `backend-sa` | backend Deployment | production |
| `postgres-sa` | postgres StatefulSet | production |
| `pg-backup-sa` | pg-daily-backup CronJob | production |

The `serviceAccountName` field is embedded directly in each Phase 3 manifest so that
CI/CD re-deploys automatically use the correct SA without a separate `kubectl patch`.

### NetworkPolicy Flow

```
default-deny-all (production)
  │
  ├── allow-dns-egress      all pods → kube-dns :53 (TCP+UDP)
  ├── frontend-policy       kong-ns → frontend :80 | frontend → DNS only
  ├── backend-policy        kong-ns → backend :3000 | monitoring → backend :3000 | backend → postgres :5432
  ├── postgres-policy       backend → postgres :5432 | pg-backup → postgres :5432
  └── allow-kong-to-production  kong-ns → frontend :80
```

---

## Phase 6 — Operational Runbooks

All runbooks assume SSH aliases configured by `phase1-kvm-infrastructure/scripts/setup-ssh.sh`,
pointing at `~/PROJECT/phase1-kvm-infrastructure/.ssh/id_rsa`.

| Runbook | Scenario | Key Commands |
|---------|----------|-------------|
| 6.1 — Worker Node Failure | Node NotReady | `kubectl drain`, `kubeadm join` |
| 6.2 — Namespace Cleanup | Remove stale resources | `kubectl delete namespace` with finalizer check |
| 6.3 — Rolling Update | Deploy new image version | `kubectl set image` or `kubectl rollout` |
| 6.4 — In-Cluster DB Restore | Restore from pg_dump backup on NFS | `pg_restore` via `postgres:17-alpine` run pod |
| 6.5 — Emergency DB Failover | In-cluster postgres down; promote db-01 | Update `bmi-secrets DATABASE_URL`, restart backend |
| 6.6 — VM Recovery | KVM VM not starting | `virsh start` or `terraform apply -target=libvirt_domain.vms["<vm>"]` |
| 6.7 — Certificate Renewal | kubeadm certs expired | `kubeadm certs renew all` |

**Important**: The Terraform target syntax is `libvirt_domain.vms["<vm-name>"]` (plural `vms`).

---

## Phase 7 — CI/CD Pipeline

### Pipeline Overview

Three-stage GitHub Actions pipeline on a self-hosted runner (the KVM hypervisor itself).

```
push to main (phase3-application-deployment/**) or workflow_dispatch
  │
  ├── Stage 1: build
  │     docker build frontend, backend, database images
  │     run backend unit test (calculateMetrics sanity check)
  │     docker save → gzip → upload as Actions artifact
  │
  ├── Stage 2: transfer
  │     write SSH key from GitHub Secret
  │     ssh-keyscan → known_hosts (required before StrictHostKeyChecking=yes)
  │     scp compressed tarballs → cp-01, w-01, w-02
  │     ctr images import on each node
  │
  └── Stage 3: deploy
        decode KUBE_CONFIG secret → ~/.kube/config
        sed-replace image tags in manifests
        kubectl apply 00-namespace → 05-frontend
        secret guard: apply 02-secret.yaml only if bmi-secrets does not exist
        kubectl rollout status (timeout 180s)
        port-forward health check on /health (HTTP 200)
        on failure: kubectl rollout undo backend + frontend
```

### Security Choices in the Pipeline

| Choice | Reason |
|--------|--------|
| `StrictHostKeyChecking=yes` | Prevents MITM if a cluster node IP is reused; `ssh-keyscan` runs first to populate `known_hosts` legitimately |
| Secret guard on `02-secret.yaml` | Prevents overwriting operator-updated secrets (e.g., after a DR failover that changed `DATABASE_URL`) |
| Images transferred via `ctr import` | Cluster has no external registry access; images are built on the runner which shares the management network |
| Self-hosted runner on hypervisor | Direct connectivity to `192.168.1.0/24` — no VPN, no port forwarding, no tunnel required |

### Required GitHub Secrets

| Secret | Content |
|--------|---------|
| `SSH_PRIVATE_KEY` | Contents of `phase1-kvm-infrastructure/.ssh/id_rsa` (ed25519 key, no passphrase) |
| `KUBE_CONFIG` | Base64-encoded `~/.kube/config` from cp-01 |

---

## Technology Version Reference

| Component | Version | Where Used |
|-----------|---------|------------|
| Ubuntu | 24.04 LTS | All 6 VM base OS |
| Terraform | >= 1.6 | Phase 1 IaC |
| dmacvicar/libvirt provider | ~> 0.8.1 | Phase 1 Terraform |
| Kubernetes | v1.32 | Phase 2 |
| containerd | latest from `containerd.io` | Phase 2 |
| Cilium CNI | latest (kubeProxyReplacement=true) | Phase 2 |
| nfs-subdir-external-provisioner | v4.0.2 | Phase 2 |
| Kong KIC | v3.2.0 | Phase 3 |
| PostgreSQL | 17 (PGDG) | Phase 1 db-01, Phase 3 in-cluster |
| Node.js | 22 LTS Alpine | Phase 3 backend |
| React + Vite | 5.x | Phase 3 frontend |
| busybox | 1.37 | Phase 3 init containers |
| Prometheus | v2.53.1 | Phase 4 |
| Node Exporter | v1.8.2 | Phase 4 |
| Grafana | 11.2.0 | Phase 4 |
| Loki | 3.1.0 | Phase 4 |
| Promtail | 3.1.0 | Phase 4 |
| HAProxy | 2.x (Ubuntu 24.04 package) | Phase 1 lb-01 |

---

## Common Troubleshooting Pointers

| Symptom | Likely Cause | Where to Look |
|---------|-------------|---------------|
| NFS PVC stuck in `Pending` | Provisioner cannot reach NFS server | Confirm `NFS_SERVER=192.168.2.40` in provisioner Deployment; check nfs-01 export for storage subnet |
| Promtail pods `CreateContainerConfigError` | `runAsNonRoot: true` conflict with `runAsUser: 0` | Check `06-promtail.yaml` securityContext |
| Backend pods `CrashLoopBackOff` after Phase 5 | PSA `restricted` blocking init container | Confirm `busybox:1.37` runs non-root (it does — busybox default is root but PSA restricted allows it with proper securityContext) |
| CI/CD `Host key verification failed` | `ssh-keyscan` did not run before SSH step | Check runner `known_hosts`; workflow must run `ssh-keyscan` before the `scp`/`ssh` commands |
| `terraform apply` fails — missing variable | `terraform.tfvars` not generated | Run `deploy-phase1.sh` rather than `terraform apply` directly |
| `kubectl apply` shows wrong resource name for Terraform | `libvirt_domain.vm` instead of `libvirt_domain.vms` | Use plural: `terraform apply -target=libvirt_domain.vms["<name>"]` |
| Grafana login fails with `admin/admin` | Credentials provisioned from Secret | Use `admin / agk@2026!` (set in `grafana-admin` Secret) |

---

## Security Notes

The `production` namespace has PSA `restricted` enforcement. All application pods must:
- Run as non-root (`runAsNonRoot: true`, `runAsUser: non-zero`)
- Use a read-only root filesystem where possible
- Not allow privilege escalation

The `phase3-application-deployment/manifests/02-secret.yaml` uses a demonstration password
(`StrongP@ssw0rd!`). This password is present in the repository's commit history and
**must be rotated** before any public or production use. In a real deployment, use
HashiCorp Vault, the Kubernetes External Secrets Operator, or GitHub Actions Secrets.

See the root `README.md` Security Note for the full credential inventory.
