# Learning Guide — Production-Grade Kubernetes Cluster on KVM
## agk Technical Assessment · IT Operations Officer

---

> **How to use this guide**  
> Each section defines every technology introduced, explains *why* it was chosen over
> alternatives, and justifies every design decision made in the repository. Read it
> alongside the phase READMEs for step-by-step commands.  
> Convert to PDF: `pandoc LEARNING_GUIDE.md -o LEARNING_GUIDE.pdf --toc --toc-depth=3`

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [Phase 1 — KVM Infrastructure](#2-phase-1--kvm-infrastructure)
3. [Phase 2 — Kubernetes Cluster](#3-phase-2--kubernetes-cluster)
4. [Phase 3 — Application Deployment](#4-phase-3--application-deployment)
5. [Phase 4 — Monitoring and Logging](#5-phase-4--monitoring-and-logging)
6. [Security Architecture (Phase 5)](#6-security-architecture-phase-5)
7. [Phase 6 — Operational Runbooks](#7-phase-6--operational-runbooks)
8. [Phase 7 — CI/CD Pipeline](#8-phase-7--cicd-pipeline)
9. [Cross-Phase Design Principles](#9-cross-phase-design-principles)
10. [Glossary](#10-glossary)

---

## 1. Project Overview

### 1.1 What This Project Is

This repository provisions a complete, production-grade infrastructure stack entirely on a
single bare-metal Linux server (the *hypervisor*). It covers every layer from hardware
virtualisation through to automated CI/CD deployments:

```
┌─────────────────────────────────────────────────────────────────┐
│  Bare-metal Linux server (hypervisor)                           │
│                                                                 │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  KVM + QEMU — hardware virtualisation                    │  │
│  └───────────────────────────────────────────────────────────┘  │
│           │ Managed by Terraform (dmacvicar/libvirt)            │
│  ┌────────┬──────────┬──────────┬──────────┬──────────────┐    │
│  │ cp-01  │  w-01    │  w-02    │  nfs-01  │ lb-01  db-01 │    │
│  └────────┴──────────┴──────────┴──────────┴──────────────┘    │
│           │                                                      │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  Kubernetes v1.32  (kubeadm, Cilium, NFS StorageClass)   │  │
│  └───────────────────────────────────────────────────────────┘  │
│           │                                                      │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  BMI Health Tracker (React + Node.js + PostgreSQL)        │  │
│  │  Kong API Gateway · Prometheus · Grafana · Loki           │  │
│  └───────────────────────────────────────────────────────────┘  │
│           │                                                      │
│  ┌───────────────────────────────────────────────────────────┐  │
│  │  GitHub Actions CI/CD (self-hosted runner on hypervisor) │  │
│  └───────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────┘
```

### 1.2 Technology Map

| Layer | Technology | Version |
|-------|-----------|---------|
| Virtualisation | KVM + QEMU | Kernel built-in |
| IaC | Terraform + libvirt provider | >= 1.6 / ~> 0.8.1 |
| VM bootstrap | cloud-init | Ubuntu 24.04 built-in |
| OS | Ubuntu | 24.04 LTS |
| Container runtime | containerd | Latest from containerd.io |
| Kubernetes | kubeadm | v1.32 |
| CNI | Cilium (eBPF) | Latest |
| Storage | NFS + nfs-subdir-external-provisioner | v4.0.2 |
| API Gateway | Kong KIC | v3.2.0 |
| Database (in-cluster) | PostgreSQL | 17 (custom image) |
| Database (DR standby) | PostgreSQL | 17 (PGDG on db-01) |
| Metrics | Prometheus + Node Exporter | v2.53.1 / v1.8.2 |
| Dashboards | Grafana | 11.2.0 |
| Logs | Loki + Promtail | 3.1.0 |
| CI/CD | GitHub Actions (self-hosted) | — |

---

## 2. Phase 1 — KVM Infrastructure

### 2.1 Virtualisation: KVM and QEMU

> **Definition — KVM (Kernel-based Virtual Machine)**  
> KVM is a Linux kernel module (`kvm.ko`) that turns the Linux kernel itself into a
> hypervisor. It exposes `/dev/kvm`, a character device that allows userspace programs
> to create and manage virtual machines using hardware virtualisation extensions
> (Intel VT-x or AMD-V). KVM does not emulate hardware — it lets VMs run instructions
> directly on the physical CPU with near-native performance.

> **Definition — QEMU (Quick EMUlator)**  
> QEMU is a userspace application that provides full hardware emulation (virtual disks,
> virtual NICs, BIOS, etc.) for virtual machines. When paired with KVM, QEMU handles
> device emulation while KVM handles CPU instruction execution. Together they form the
> standard open-source virtualisation stack on Linux.

> **Definition — libvirt**  
> libvirt is a C library and daemon (`libvirtd`) that provides a stable management API
> over multiple hypervisors including KVM/QEMU, Xen, and LXC. It handles network bridge
> creation, storage pool management, and VM lifecycle (define, start, stop, destroy).
> The `virsh` CLI and the Terraform libvirt provider both talk to libvirt.

**Why KVM over VMware/Hyper-V/VirtualBox?**  
KVM is built into the Linux kernel — no licence cost, no proprietary agent, no separate
installer. For a bare-metal Linux server in an IT operations context, KVM is the natural
choice. VMware requires vSphere licences; Hyper-V requires Windows Server; VirtualBox
targets desktop use and lacks the management APIs needed for Infrastructure-as-Code.

---

### 2.2 Infrastructure as Code: Terraform

> **Definition — Terraform**  
> Terraform is an open-source IaC tool that declaratively describes infrastructure in
> HCL (HashiCorp Configuration Language) files. A *provider* is a plugin that translates
> HCL resource definitions into API calls against a specific platform. The
> `dmacvicar/libvirt` provider translates `libvirt_domain`, `libvirt_network`, and
> `libvirt_volume` resource blocks into libvirt API calls.

> **Definition — Terraform State**  
> Terraform maintains a state file (`terraform.tfstate`) that records the real-world IDs
> of every resource it manages. On each `terraform apply`, Terraform compares the desired
> state (HCL files) against the current state (state file) and computes a diff — only
> creating, updating, or destroying resources that need to change.

**Why Terraform over manual `virsh` commands?**  
Manual `virsh` commands are not repeatable, not version-controlled, and not diffable.
Terraform allows the entire infrastructure to be re-created identically from a single
`terraform apply` — critical for disaster recovery and for demonstrating the deployment
to an assessor. Every change to the infrastructure is tracked in git history.

**Key Terraform files in this project:**

| File | Purpose |
|------|---------|
| `main.tf` | Provider configuration and cloud-init template rendering |
| `networks.tf` | Three `libvirt_network` resources (management, storage, external) |
| `vms.tf` | Six `libvirt_domain` resources using `for_each` over `var.vm_configs` |
| `variables.tf` | `vm_configs` map — all VM parameters in one central location |
| `outputs.tf` | Prints management IPs after apply for copy-paste into SSH config |

**`for_each` pattern in `vms.tf`:**  
Rather than repeating a VM resource block six times, `vms.tf` uses a single
`resource "libvirt_domain" "vms"` with `for_each = var.vm_configs`. Each key in the
map (`"cp-01"`, `"w-01"`, etc.) becomes one VM. This means adding a seventh VM requires
only a new entry in the map — the VM block itself never changes.

**`terraform.tfvars` — why it is not committed:**  
The deploy script generates `terraform.tfvars` at runtime and injects the SSH public
and private key into Terraform variables. The private key must never be committed to
version control — `.gitignore` excludes `terraform.tfvars` for this reason. If the file
is missing, re-run `deploy-phase1.sh` which regenerates it.

---

### 2.3 VM Bootstrap: cloud-init

> **Definition — cloud-init**  
> cloud-init is the industry-standard mechanism for initialising cloud and virtual
> machine instances on first boot. It reads a YAML file (`user-data`) from a special
> data source (in this project, a virtual ISO attached to each VM) and performs actions:
> creating users, writing files, installing packages, running commands.  
> Ubuntu 24.04 cloud images include cloud-init pre-installed.

**cloud-init YAML sections used in this project:**

| Section | What it does | Example use |
|---------|-------------|-------------|
| `users` | Create OS users and set SSH authorised keys | Add `ubuntu` user with `sudo` and the Terraform-injected SSH key |
| `packages` | Install packages via apt | `nfs-common`, `haproxy`, etc. |
| `write_files` | Write file content to disk before `runcmd` runs | HAProxy config, PostgreSQL config, NFS exports |
| `runcmd` | Run shell commands in order after packages are installed | PGDG repo setup, service enable, exportfs |
| `network` | Configure Netplan static IP assignments | Assign management/storage/external IPs per VM |

**Why `routes:` instead of `gateway4:`:**  
Ubuntu 24.04 uses Netplan >= 0.102. The `gateway4:` key was deprecated in favour of
`routes:` with `to: default / via: <gateway>`. Using the deprecated key produces a
warning and may stop working in future Netplan versions. Every cloud-init file in this
project uses the current syntax.

**Per-role cloud-init files:**

| VM | File | Key Additions |
|----|------|--------------|
| cp-01 | `control-plane.yaml` | Kubernetes apt repo, containerd.io, kubeadm/kubelet/kubectl |
| w-01, w-02 | `worker.yaml` | Same K8s packages; data directory pre-created |
| nfs-01 | `storage.yaml` | `nfs-kernel-server`; `/etc/exports` with storage-subnet restriction; 50 GB disk mounted |
| lb-01 | `load-balancer.yaml` | `haproxy`; config written with TCP health checks on Kong NodePorts |
| db-01 | `database.yaml` | PGDG apt repo; `postgresql-17`; 30 GB data disk mounted at `/var/lib/postgresql` |

---

### 2.4 Network Design

**Three isolated virtual networks:**

```
 Management  192.168.1.0/24  (virbr1)  ── all 6 VMs ── SSH, K8s API, kubeadm join
 Storage     192.168.2.0/24  (virbr2)  ── nfs-01     ── NFS data transfer (port 2049)
 External    192.168.100.0/24 (virbr3)  ── lb-01     ── HTTP/HTTPS from clients
```

**Why three networks instead of one?**

1. **Security**: NFS export is restricted to `192.168.2.0/24` only. Kubernetes nodes
   and application pods cannot reach the NFS server through the management network.
   An attacker who compromises a pod cannot directly attempt NFS exploits.

2. **Performance**: NFS storage traffic (which can be high volume during PVC writes) is
   isolated from management traffic (Kubernetes API calls, kubelet heartbeats, SSH).
   They never compete for the same bandwidth.

3. **Clarity**: A separate external network makes it unambiguous which traffic is
   user-facing. HAProxy on lb-01 is the only VM with a foot in the external network —
   all other VMs are unreachable from the external CIDR.

**Critical IP distinction for NFS:**

| IP | Interface | Purpose |
|----|-----------|---------|
| 192.168.1.40 | nfs-01 eth0 (management) | SSH access only |
| 192.168.2.40 | nfs-01 eth1 (storage) | NFS mounts — this is what k8s nodes use |

Every reference to the NFS server in Kubernetes manifests, the provisioner Deployment,
and the runbooks must use `192.168.2.40`. Using `192.168.1.40` for NFS would be refused
by the NFS server because `/etc/exports` allows only the `192.168.2.0/24` subnet.

---

### 2.5 PostgreSQL 17 Standalone on db-01

**Why a separate VM for PostgreSQL?**  
db-01 is a **Disaster Recovery (DR) target**, not part of normal operations. If the
Kubernetes cluster fails completely (all VMs down, etcd corruption, control plane
unreachable), the application's data is not lost — it exists on db-01's dedicated 30 GB
disk. Runbook 6.5 describes how to promote db-01 to the live database by updating a
single Kubernetes Secret.

**Why PostgreSQL 17 via PGDG, not Ubuntu's default package?**  
Ubuntu 24.04 ships `postgresql` version 16 as the default apt package. The in-cluster
database uses `postgres:17-alpine`. Using different major versions between the in-cluster
database and the DR standby would make `pg_dump`/`pg_restore` operations unreliable
(pg_dump output from PG17 may use formats not understood by PG16 restore tools).
The PGDG (PostgreSQL Global Development Group) apt repository provides the official
PG17 packages for Ubuntu 24.04.

---

## 3. Phase 2 — Kubernetes Cluster

### 3.1 What Kubernetes Is

> **Definition — Kubernetes**  
> Kubernetes (K8s) is an open-source container orchestration system. It automates
> deployment, scaling, and operations of application containers across a cluster of
> machines. Applications are described as desired state (YAML manifests); Kubernetes
> continuously reconciles actual state toward desired state through control loops.

**Core components — Control Plane (runs on cp-01):**

| Component | Role |
|-----------|------|
| `kube-apiserver` | The REST API gateway for all cluster operations. All other components talk through it. |
| `etcd` | Distributed key-value store that holds all cluster state (pod specs, secrets, endpoints, etc.) |
| `kube-scheduler` | Assigns unscheduled pods to nodes based on resource requests, affinity rules, and taints |
| `kube-controller-manager` | Runs control loops: ReplicaSet controller, Node controller, Endpoint controller, etc. |

**Core components — Worker Nodes (w-01, w-02):**

| Component | Role |
|-----------|------|
| `kubelet` | Agent on every node. Watches the apiserver for pod assignments; starts/stops containers via the CRI |
| Container runtime (`containerd`) | Actually runs containers. Kubelet talks to it via the CRI (Container Runtime Interface) |
| Cilium (replaces kube-proxy) | Handles service load balancing using eBPF instead of iptables |

---

### 3.2 kubeadm — Why and How

> **Definition — kubeadm**  
> kubeadm is the CNCF-endorsed tool for bootstrapping a production Kubernetes cluster.
> It generates TLS certificates for all control-plane components, starts etcd as a
> static pod, creates the control-plane static pod manifests, configures RBAC bootstrap
> tokens, and produces the worker join command.

**Why kubeadm over alternatives?**

| Tool | Verdict | Reason |
|------|---------|--------|
| kubeadm | **Chosen** | Explicit, auditable, production standard. Every flag is documented. |
| k3s | Not chosen | Bundles Traefik and SQLite by default; hides implementation details |
| microk8s | Not chosen | Snap-based; non-standard package management; limited control over CNI |
| kind/minikube | Not chosen | Development tools only; not production-capable |

**`kubeadm init` flags used and why:**

| Flag | Value | Justification |
|------|-------|--------------|
| `--apiserver-advertise-address` | 192.168.1.10 | Management NIC only — API traffic must not leak to storage or external networks |
| `--pod-network-cidr` | 10.244.0.0/16 | Required by Cilium's Kubernetes IPAM mode; must not overlap host or service CIDRs |
| `--service-cidr` | 10.96.0.0/12 | Kubernetes default; provides over 1 million ClusterIP addresses |
| `--control-plane-endpoint` | 192.168.1.10:6443 | Stable endpoint for workers to join; could point to a load balancer if HA control plane were added |
| `--token-ttl` | 24h | Short-lived join token limits the window for token abuse |
| `--upload-certs` | — | Encrypts control-plane certificates into etcd, enabling a second control plane to join without manual cert transfer |

---

### 3.3 Container Runtime: containerd

> **Definition — containerd**  
> containerd is an industry-standard container runtime that manages the full container
> lifecycle: image pull, storage, networking handoff (to CNI), and execution. It
> implements the Kubernetes CRI (Container Runtime Interface), allowing kubelet to
> interact with it through a defined API.

**Why containerd, not Docker?**  
Docker is a developer-focused tool that includes a CLI, build system, Compose, and a
daemon (`dockerd`) — all of which add overhead and complexity. Kubernetes removed direct
Docker support (`dockershim`) in v1.24. containerd is the runtime that Docker itself
uses internally; running containerd directly removes the intermediary layer.

**Critical configuration — cgroup driver:**  
Ubuntu 24.04 uses systemd as its init system, which manages cgroup hierarchies.
The containerd config must set `SystemdCgroup = true` (capital S, equals sign, inside
the `[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]` block).
Mismatches between kubelet and containerd cgroup drivers cause node instability and
pod evictions. The old key `systemd_cgroup = true` (lowercase, used in containerd v1)
has no effect in containerd v2.

---

### 3.4 CNI: Cilium and eBPF

> **Definition — CNI (Container Network Interface)**  
> CNI is a specification that defines how networking plugins integrate with container
> runtimes. When Kubernetes creates a pod, it calls the CNI plugin to: assign an IP
> address, set up routing rules, and configure network namespaces. Without a CNI, pods
> cannot communicate.

> **Definition — eBPF (extended Berkeley Packet Filter)**  
> eBPF is a Linux kernel technology that allows sandboxed programs to run in the kernel
> without modifying kernel source code or loading kernel modules. eBPF programs are
> verified for safety before loading, then JIT-compiled for near-native performance.
> In networking, eBPF programs can intercept packets at the earliest possible point
> (before they enter the network stack) and make routing decisions.

> **Definition — Cilium**  
> Cilium is a Kubernetes CNI plugin that uses eBPF to implement pod networking,
> NetworkPolicies, service load balancing, and observability. It is CNCF Graduated.

**Why Cilium over alternatives?**

| CNI | Dataplane | NetworkPolicy | kube-proxy replacement | Production grade |
|-----|-----------|--------------|------------------------|-----------------|
| **Cilium** | eBPF | Full L3–L7 | Yes (full) | CNCF Graduated |
| Calico | iptables / eBPF (optional) | L3–L4 | Partial | CNCF Graduated |
| Flannel | iptables | None | No | Stable |
| Weave | iptables | Basic | No | Deprecated |

**The kube-proxy problem:**  
`kubeadm init` deploys kube-proxy as a DaemonSet by default. kube-proxy manages
service routing using iptables rules. When Cilium is installed with
`kubeProxyReplacement=true`, Cilium takes over all service routing using eBPF maps.
If kube-proxy is left running, both systems attempt to manage the same routing tables
simultaneously — leading to unpredictable packet routing and sporadic connection failures.

**The fix: explicitly delete kube-proxy after Cilium is installed:**
```bash
kubectl delete -n kube-system daemonset kube-proxy
kubectl delete -n kube-system configmap kube-proxy
```

**Performance advantage of eBPF vs iptables:**  
iptables is a chain of rules evaluated linearly — O(n) per packet where n is the number
of rules. A cluster with hundreds of services generates thousands of iptables rules.
eBPF uses hash-map lookups — O(1) regardless of cluster size. This difference becomes
significant under high traffic or in large clusters.

---

### 3.5 Persistent Storage: NFS

> **Definition — PersistentVolume (PV)**  
> A PersistentVolume is a Kubernetes resource that represents a piece of storage in the
> cluster. It is provisioned either manually by an administrator or automatically by a
> StorageClass provisioner.

> **Definition — PersistentVolumeClaim (PVC)**  
> A PVC is a request for storage by a user or pod. It specifies size and access mode.
> Kubernetes binds the PVC to a suitable PV automatically.

> **Definition — StorageClass**  
> A StorageClass describes the type of storage available. When a PVC references a
> StorageClass, the associated provisioner automatically creates a PV to satisfy the
> claim. The `nfs-client` StorageClass uses the `nfs-subdir-external-provisioner`.

> **Definition — nfs-subdir-external-provisioner**  
> A Kubernetes Deployment that watches for new PVCs and, when one is created with the
> `nfs-client` StorageClass, creates a subdirectory on the NFS share and returns a PV
> bound to that subdirectory. This gives each PVC its own isolated directory on the
> shared NFS mount.

**Access modes:**

| Mode | Abbreviation | Meaning | Used by |
|------|-------------|---------|---------|
| ReadWriteOnce | RWO | One node can mount read-write | postgres PVC |
| ReadWriteMany | RWX | Many nodes can mount read-write | pg-backup-storage PVC |
| ReadOnlyMany | ROX | Many nodes can mount read-only | Not used here |

**Why NFS over distributed storage (Longhorn/Rook-Ceph)?**  
Longhorn and Rook-Ceph require multiple OSDs, monitors, and manager processes — adding
3-5 extra pods per node and significant CPU/RAM overhead. For an assessment-scale
3-node cluster with a dedicated NFS VM, the overhead is not justified. NFS delivers
ReadWriteMany natively and is fully sufficient for the workload size.

---

### 3.6 Namespace Strategy

This project uses three namespaces:

| Namespace | Workloads | PSA Level |
|-----------|-----------|-----------|
| `production` | Frontend, backend, PostgreSQL, pg-backup CronJob | restricted |
| `monitoring` | Prometheus, Node Exporter, Grafana, Loki, Promtail | baseline |
| `kong` | Kong Ingress Controller | baseline |

**Why a single `production` namespace instead of per-tier namespaces?**  
With Kong as the ingress layer and Cilium NetworkPolicies enforcing tier isolation via
`tier:` pod labels, a single namespace provides equivalent security to three separate
namespaces — with less operational complexity. One namespace means one PSA policy,
one set of RBAC bindings, and simpler NetworkPolicy selectors. Per-tier namespaces
become valuable when different teams own different tiers (separate quotas, separate
RBAC delegates), which is not the case here.

---

### 3.7 ResourceQuota and LimitRange

> **Definition — ResourceQuota**  
> A ResourceQuota limits the total amount of resources (CPU, memory, pod count, PVC
> count) that can be consumed by all pods in a namespace. It prevents one namespace
> from monopolising cluster resources.

> **Definition — LimitRange**  
> A LimitRange sets default resource requests and limits for containers in a namespace.
> When a ResourceQuota is active, Kubernetes rejects pods that have no resource spec.
> LimitRange injects defaults so that even pods without explicit resource fields are
> accepted and counted against the quota.

**Why both are needed together:**  
A ResourceQuota without a LimitRange causes pod admission failures for any manifest
that omits resource fields (many helm charts and tutorial manifests do this).
A LimitRange without a ResourceQuota has no enforcement — a single pod could consume
all node CPU. Used together, they provide complete namespace-level resource governance.

---

### 3.8 PodDisruptionBudgets

> **Definition — PodDisruptionBudget (PDB)**  
> A PDB specifies the minimum number (or percentage) of pods of a set that must remain
> available during voluntary disruptions — node drains, rolling upgrades, or cluster
> maintenance. The eviction API checks PDBs before evicting a pod.

**Why PDBs matter in practice:**  
Without a PDB, `kubectl drain <node>` will evict ALL pods on that node simultaneously —
including both replicas of the backend Deployment if they happen to be co-located. This
causes a complete service outage during routine maintenance. With `minAvailable: 1`,
the drain stalls after evicting the first replica until the rescheduled pod is Ready,
then proceeds with the second.

---

## 4. Phase 3 — Application Deployment

### 4.1 The Three-Tier Application

The BMI Health Tracker follows a classic three-tier architecture:

```
Client browser
      │ HTTP
      ▼
HAProxy (lb-01:80)                ← Layer 4 TCP proxy
      │ → NodePort 30080
      ▼
Kong KIC (kong namespace)         ← Layer 7 API Gateway
      │ / → frontend-service:80
      │ /api → backend-service:3000
      ▼                ▼
  Frontend          Backend        ← Stateless, 2 replicas each
  React+Vite        Node.js 22
  port 80           port 3000
                       │ 5432
                       ▼
                  PostgreSQL 17    ← StatefulSet, 1 replica
                  NFS PVC 10Gi
```

---

### 4.2 Kubernetes Workload Types

> **Definition — Deployment**  
> A Deployment manages a set of identical, stateless pod replicas. It ensures the
> desired number of replicas are running and handles rolling updates (creating new pods
> before terminating old ones). Used for frontend and backend.

> **Definition — StatefulSet**  
> A StatefulSet manages pods that require stable identity and persistent storage.
> Each pod gets a predictable hostname (`postgres-0`) and its own PVC (from
> `volumeClaimTemplates`). Pods start and stop in order. Used for PostgreSQL.

> **Definition — DaemonSet**  
> A DaemonSet ensures one pod runs on every node (or every matching node). Used for
> Node Exporter (metrics from every node) and Promtail (logs from every node).

> **Definition — CronJob**  
> A CronJob creates a Job on a schedule (cron syntax). The pg-dump CronJob runs daily
> at 02:00 UTC, creates a Job pod, runs `pg_dump`, writes the backup to NFS, then
> terminates. The pod does not remain running between executions.

**Why StatefulSet for PostgreSQL, not Deployment?**

| Requirement | Deployment | StatefulSet |
|-------------|-----------|------------|
| Stable pod hostname | No (random hash) | Yes (`postgres-0`) |
| Per-replica PVC | No (shared) | Yes (one PVC per pod) |
| Ordered startup | No | Yes (postgres-0 before postgres-1) |
| Ordered shutdown | No | Yes (reverse order) |

The backend's `DATABASE_URL` references `postgres-service.production.svc.cluster.local`
— this resolves to the headless service, which returns the pod IP of `postgres-0`
directly (bypassing ClusterIP load balancing, which would be wrong for a single-replica
database).

---

### 4.3 Kubernetes Service Types

> **Definition — ClusterIP Service**  
> A ClusterIP Service assigns a stable virtual IP address within the cluster. Traffic
> to the ClusterIP is load-balanced across matching pods. The IP is only reachable from
> within the cluster. Used for backend-service, frontend-service, postgres-service.

> **Definition — NodePort Service**  
> A NodePort Service opens a port (30000–32767) on every cluster node. External traffic
> to `<any-node-ip>:<nodePort>` is forwarded to the backing pods. HAProxy on lb-01 sends
> traffic to the workers' NodePort 30080. Used for Kong KIC.

> **Definition — Headless Service (clusterIP: None)**  
> A headless service has no ClusterIP. DNS queries for the service name return the pod
> IPs directly. StatefulSet pods get stable DNS names: `postgres-0.postgres-service`.
> This allows the backend to connect to the specific postgres pod, not a random one.

---

### 4.4 ConfigMap and Secret

> **Definition — ConfigMap**  
> A ConfigMap stores non-sensitive configuration data as key-value pairs. Pods consume
> them as environment variables (`configMapKeyRef`) or as mounted files. Used for
> `PORT=3000`, `DB_HOST=postgres-service`, `NODE_ENV=production`.

> **Definition — Secret**  
> A Secret stores sensitive data (passwords, keys, certificates) in base64-encoded form.
> Kubernetes stores Secrets in etcd; access is controlled by RBAC. Pods consume them
> via `secretKeyRef` for environment variables or as mounted volumes.

**Why use `secretKeyRef` instead of plain `value:`?**  
A plain `value: mypassword` in a Deployment spec is visible to anyone who can run
`kubectl get deployment -o yaml`. With `secretKeyRef`, the Deployment spec contains
only a reference — the actual value is stored in the Secret and injected by the kubelet
at pod creation time. To see the value, an attacker needs `kubectl get secret` access,
which is controlled by separate RBAC rules.

---

### 4.5 Kong API Gateway

> **Definition — API Gateway**  
> An API gateway is a single entry point for all client requests. It handles cross-cutting
> concerns: routing, authentication, rate limiting, TLS termination, request logging. This
> keeps application code free of these concerns.

> **Definition — Kong KIC (Kubernetes Ingress Controller)**  
> Kong KIC is the Kubernetes-native distribution of Kong. It reads Kubernetes Ingress
> and KongIngress custom resources and configures the Kong proxy accordingly. DB-less
> mode means Kong's routing configuration is stored in Kubernetes CRDs, not in a
> separate PostgreSQL database — eliminating a database dependency in the ingress layer.

**Route design:**

| Path | Upstream | Strip path? | Reason |
|------|---------|-------------|--------|
| `/` | frontend-service:80 | No | Frontend serves static files from `/` |
| `/api` | backend-service:3000 | No | Backend exposes routes at `/api/...` |

**Why NodePort, not LoadBalancer type for Kong?**  
`type: LoadBalancer` requires a cloud provider or a bare-metal load balancer controller
(like MetalLB) to assign an external IP. On a KVM cluster with no cloud provider, the
service would remain `<pending>` indefinitely. NodePort (30080/30443) is the correct
choice — HAProxy on lb-01 handles the external-to-internal bridging.

**Why HAProxy uses TCP check (not `option httpchk`)?**  
Kong's proxy listens on NodePort 30080 and forwards requests to upstream services based
on routing rules. There is no global `/health` path on the proxy port itself — a plain
HTTP `GET /` would return a 404 from Kong (no route matches without a `Host` header).
A TCP check (`check`) verifies only that the port is open and accepting connections,
which is sufficient for HAProxy to determine node availability.

---

### 4.6 HorizontalPodAutoscaler

> **Definition — HPA (HorizontalPodAutoscaler)**  
> An HPA automatically adjusts the number of pod replicas in a Deployment based on
> observed metrics (CPU, memory, or custom metrics). It queries the Metrics Server for
> current utilisation and scales up or down within configured min/max bounds.

The frontend HPA scales between 2 and 5 replicas at 70% CPU utilisation threshold.
The 70% threshold provides headroom — at 70% CPU, there is still 30% headroom before
degradation, and scaling up takes 30–60 seconds (time for new pod to become Ready).

**Metrics Server is required for HPA.** Without it, `kubectl top nodes` and HPA both
show `<unknown>`. Metrics Server is installed separately from Prometheus because it
provides the `metrics.k8s.io` API that HPA queries — Prometheus is a separate
monitoring system that does not expose this API.

---

## 5. Phase 4 — Monitoring and Logging

### 5.1 Observability Pillars

Modern systems observability rests on three pillars:

| Pillar | Tool | What it answers |
|--------|------|----------------|
| **Metrics** | Prometheus + Grafana | "How is the system performing over time?" |
| **Logs** | Loki + Promtail | "What happened at a specific time?" |
| **Traces** | (not in this project) | "Where did this request spend its time?" |

---

### 5.2 Prometheus

> **Definition — Prometheus**  
> Prometheus is an open-source monitoring system with a time-series database. It
> collects metrics by *pulling* (scraping) HTTP endpoints that expose data in the
> Prometheus text format. Each metric has a name, labels (key-value dimensions), and a
> timestamp.

**Pull model vs push model:**

| Model | How it works | Advantage |
|-------|-------------|-----------|
| Pull (Prometheus) | Prometheus scrapes targets on its schedule | Prometheus controls the scrape rate; targets don't need to know Prometheus exists |
| Push (InfluxDB, StatsD) | Targets send metrics to a collector | Easier for short-lived jobs; harder to control rate |

Pull is preferred for long-running services because: (a) Prometheus can detect when a
target goes missing (scrape fails), (b) a single Prometheus config file controls all
scrape intervals, (c) targets are decoupled from the monitoring system.

**Kubernetes Service Discovery:**  
Prometheus uses the Kubernetes API to automatically discover all pods, services, and
nodes. When a new pod is deployed, Prometheus discovers it within the next scrape cycle
(typically 15 seconds) — no manual config change required.

---

### 5.3 Grafana

> **Definition — Grafana**  
> Grafana is an open-source visualisation and dashboarding platform. It does not store
> metrics — it queries data sources (Prometheus, Loki, etc.) and renders the results.
> Dashboards can be provisioned from files (GitOps-friendly) or created through the UI.

**Credential management:**  
Grafana's admin credentials are stored in a Kubernetes Secret (`grafana-admin`) and
injected as environment variables via `secretKeyRef`. The Deployment spec contains only
the Secret key name — not the actual password. This means:

- `kubectl get deployment grafana -o yaml` does not reveal the password
- The password can be rotated by updating the Secret and restarting the pod
- The credentials are not in the git repository's commit history

**Access:** `http://192.168.100.10:30030` — routed through HAProxy on lb-01 (external
network) → NodePort 30030 on any worker → Grafana pod in monitoring namespace.

Default credentials: `admin / agk@2026!`

---

### 5.4 Loki and Promtail

> **Definition — Loki**  
> Loki is a log aggregation system designed by Grafana Labs. Unlike Elasticsearch, Loki
> indexes only log *labels* (not the full log content), making it significantly cheaper
> to operate at scale. Log content is compressed and stored as chunks. Queries use
> LogQL (similar to PromQL).

> **Definition — Promtail**  
> Promtail is the log collection agent for Loki. It runs as a DaemonSet (one pod per
> node), tails log files from `/var/log/pods/*`, attaches Kubernetes labels, and ships
> log lines to Loki.

**Why Loki over Elasticsearch (ELK stack)?**

| Criteria | Loki | Elasticsearch |
|----------|------|--------------|
| Resource usage | Very low (index only labels) | High (full-text index of all content) |
| Grafana integration | Native datasource | Requires Kibana or plugin |
| Query language | LogQL (familiar if you know PromQL) | Lucene / KQL |
| Suitable for this scale | Yes | Over-engineered |

**Why Promtail must run as root (`runAsUser: 0`):**  
Pod log files on the node filesystem (`/var/log/pods/*/...`) are owned by root (written
by containerd with root permissions). Promtail must read these files. Setting
`runAsNonRoot: true` with `runAsUser: 0` is a contradictory securityContext — Kubernetes
rejects the pod immediately at admission because `runAsUser: 0` IS the root user. The
`monitoring` namespace therefore uses PSA `baseline` (which allows root containers)
rather than `restricted` (which forbids them).

---

### 5.5 PostgreSQL Backup Strategy

**Daily pg_dump CronJob:**

| Parameter | Value | Reason |
|-----------|-------|--------|
| Schedule | `0 2 * * *` | 02:00 UTC — lowest traffic window |
| Format | `--format=custom` (`-Fc`) | Compressed; supports parallel restore with `pg_restore -j` |
| Retention | 30 days (older dirs deleted) | Balance between storage cost and recovery options |
| Storage | NFS PVC `pg-backup-storage` (20 Gi) | Persistent across pod restarts; accessible from any node |
| Image | `postgres:17-alpine` | Must match cluster database version exactly for dump compatibility |

> **Definition — RPO (Recovery Point Objective)**  
> The maximum acceptable amount of data loss measured in time. With daily backups,
> RPO = 24 hours — in the worst case, one day of transactions may be lost.

> **Definition — RTO (Recovery Time Objective)**  
> The maximum acceptable time to restore service after a failure. With the restore
> procedure in Runbook 6.4, RTO = 30 minutes for an in-cluster restore from the most
> recent backup.

---

## 6. Security Architecture (Phase 5)

### 6.1 Defence in Depth

Security in this cluster operates at multiple independent layers. Compromising one layer
does not grant access to the others:

```
Layer 1 — Host firewall (UFW):        block non-authorised ports per VM
Layer 2 — Kubernetes NetworkPolicies: block non-authorised pod-to-pod traffic
Layer 3 — RBAC:                       block non-authorised API server access
Layer 4 — Pod Security Admission:     block non-compliant pod specs at admission
Layer 5 — ServiceAccounts:            limit each pod's API server identity
Layer 6 — Secrets management:         avoid plaintext credentials in specs
```

---

### 6.2 Pod Security Admission (PSA)

> **Definition — Pod Security Admission**  
> PSA is a built-in Kubernetes admission controller (stable since v1.25) that enforces
> security standards at the namespace level. When a pod is created, PSA evaluates its
> spec against a policy level and either allows, warns, or denies it.

**Three PSA levels:**

| Level | What it enforces |
|-------|----------------|
| `privileged` | No restrictions — for trusted system workloads |
| `baseline` | Blocks known dangerous settings (hostNetwork for most workloads, privileged containers). Allows root. |
| `restricted` | Strict: must run as non-root, no privilege escalation, read-only root FS required |

**Namespace assignments in this project:**

| Namespace | Level | Justification |
|-----------|-------|--------------|
| `production` | `restricted` | App pods are stateless and designed to run non-root |
| `monitoring` | `baseline` | Promtail needs root for log access; Node Exporter needs `hostNetwork` |
| `kong` | `baseline` | KIC requires elevated capabilities for network programming |

---

### 6.3 RBAC (Role-Based Access Control)

> **Definition — RBAC**  
> RBAC is the Kubernetes mechanism for controlling who (a user, group, or ServiceAccount)
> can perform which actions (verbs: get, list, create, delete) on which resources
> (pods, secrets, deployments).

**Key resource types:**

| Resource | Scope | Purpose |
|----------|-------|---------|
| `Role` | Namespace | Grants permissions within one namespace |
| `ClusterRole` | Cluster-wide | Grants permissions across all namespaces or for cluster-scoped resources |
| `RoleBinding` | Namespace | Binds a Role to a subject (user, SA) within a namespace |
| `ClusterRoleBinding` | Cluster-wide | Binds a ClusterRole to a subject cluster-wide |

**Principle of least privilege in this project:**  
Each tier gets a dedicated ServiceAccount with only the permissions it needs:

| ServiceAccount | Permissions | Reason |
|---------------|------------|--------|
| `frontend-sa` | None | Frontend serves static files; no API server access needed |
| `backend-sa` | GET on `bmi-secrets`, GET on `bmi-config` | Reads DB credentials at startup |
| `postgres-sa` | None | PostgreSQL has no Kubernetes API interactions |
| `pg-backup-sa` | GET on `bmi-secrets` | Reads DB password for `pg_dump` |

**`automountServiceAccountToken: false`:**  
By default, Kubernetes mounts a ServiceAccount token into every pod at
`/var/run/secrets/kubernetes.io/serviceaccount/token`. This token can be used to call
the Kubernetes API. For pods that do not need API access, mounting the token is
unnecessary attack surface — if the pod is compromised, the attacker gains an API
credential for free. Setting `automountServiceAccountToken: false` prevents the mount.

---

### 6.4 NetworkPolicies — Zero-Trust Model

> **Definition — NetworkPolicy**  
> A Kubernetes resource that selects a set of pods and specifies which ingress (incoming)
> and egress (outgoing) traffic is allowed. Traffic not explicitly allowed is denied.
> NetworkPolicies are enforced by the CNI plugin — Cilium in this project.

**Zero-trust baseline:**  
The first policy in the `production` namespace is `default-deny-all`, which selects all
pods (`podSelector: {}`) and denies all ingress AND egress. Every subsequent policy
is an explicit exception. This means:
- A new pod has zero network access until a policy grants it
- A misconfigured pod cannot accidentally reach the database
- An attacker who exploits the frontend cannot pivot to the database

**`kubernetes.io/metadata.name` vs custom namespace labels:**  
NetworkPolicy `namespaceSelector` matches on pod labels. Using a custom label
(`name: frontend`) is risky because any cluster user with `kubectl label namespace`
permission could add that label to their own namespace and gain access. The
`kubernetes.io/metadata.name` label is set by the Kubernetes API server itself and
cannot be overridden by non-admin users — it provides a tamper-resistant namespace
identity for NetworkPolicy selectors.

**Complete traffic matrix for `production` namespace:**

```
Kong namespace → frontend pod :80     ← allowed (frontend-policy + allow-kong-to-production)
Kong namespace → backend pod  :3000   ← allowed (backend-policy)
monitoring ns  → backend pod  :3000   ← allowed (backend-policy — Prometheus scrapes /metrics)
backend pod    → postgres pod :5432   ← allowed (backend-policy egress + postgres-policy ingress)
pg-backup pod  → postgres pod :5432   ← allowed (postgres-policy ingress)
All pods       → kube-dns    :53      ← allowed (allow-dns-egress — TCP+UDP)
frontend pod   → backend pod          ← DENIED (frontend is a static SPA; browser calls /api through Kong)
postgres pod   → anywhere             ← DENIED (no egress allowed from database tier)
```

---

### 6.5 UFW Host-Level Firewall

> **Definition — UFW (Uncomplicated Firewall)**  
> UFW is a frontend for `iptables`/`nftables` on Ubuntu. It provides simple commands
> (`ufw allow`, `ufw deny`) to manage host-level packet filtering rules.

**Why UFW in addition to Kubernetes NetworkPolicies?**  
Kubernetes NetworkPolicies protect pod-to-pod traffic within the cluster. They do not
protect:
- The hypervisor's SSH port from brute-force attacks
- The KVM management APIs from unauthorised access
- NFS port 2049 on nfs-01 from traffic originating outside the storage network

UFW at the VM host level adds an independent layer — even if the Kubernetes cluster is
completely compromised, the host firewall limits what an attacker can reach.

---

## 7. Phase 6 — Operational Runbooks

### 7.1 What a Runbook Is

> **Definition — Runbook**  
> A runbook is a documented set of procedures for performing a specific operational task
> — typically one that is infrequent, high-stakes, or time-pressured (like incident
> response). A good runbook is self-contained: an operator who has never seen the system
> before should be able to follow it without external knowledge.

**Runbooks in this project:**

| Runbook | Scenario | Key Concept |
|---------|----------|------------|
| 6.1 | Worker node failure | Node drain, kubeadm join re-process |
| 6.2 | Namespace cleanup | Finalizer removal, resource ordering |
| 6.3 | Rolling update | kubectl set image, rollout status |
| 6.4 | In-cluster DB restore | pg_restore from NFS backup |
| 6.5 | Emergency DB failover to db-01 | Secret update, application reconnect |
| 6.6 | VM recovery | virsh start, Terraform re-apply |
| 6.7 | Certificate renewal | kubeadm certs renew all |

---

### 7.2 Disaster Recovery Architecture

**Normal operation:**
```
Backend → postgres-service (K8s) → postgres-0 pod → NFS PVC (nfs-01 disk)
                                                    ↕ daily pg_dump at 02:00 UTC
                                                 pg-backup-storage PVC (nfs-01 disk)
```

**After in-cluster postgres failure (Runbook 6.4 — RTO: 30 min):**
```
pg_restore pod → reads pg-backup-storage PVC → writes to new postgres PVC
Backend → postgres-service → postgres-0 (newly restored) → resumes normal operation
```

**After complete cluster failure (Runbook 6.5 — RTO: 30 min):**
```
db-01 VM (PostgreSQL 17 standalone) ← imported from last pg_dump backup
kubectl edit secret bmi-secrets → DATABASE_URL points to 192.168.1.60
kubectl rollout restart deployment/backend → reconnects to db-01
```

**Why db-01 is on the management network, not the storage network:**  
The storage network (192.168.2.0/24) is for NFS traffic only. Application connections
(TCP 5432) go over the management network. db-01 has its management NIC at 192.168.1.60
— backend pods connect here during failover. The storage network is irrelevant to the
PostgreSQL protocol.

---

## 8. Phase 7 — CI/CD Pipeline

### 8.1 GitHub Actions Concepts

> **Definition — GitHub Actions**  
> GitHub Actions is a CI/CD platform built into GitHub. Workflows are YAML files in
> `.github/workflows/`. A workflow is triggered by events (push, pull request,
> schedule, manual dispatch) and runs one or more jobs.

> **Definition — Self-hosted runner**  
> Instead of GitHub's cloud runners, a self-hosted runner is a process running on your
> own machine that polls GitHub for workflow jobs. When a job is assigned to
> `runs-on: self-hosted`, GitHub sends the job to this runner. In this project, the
> runner runs on the KVM hypervisor — giving it direct access to the cluster's
> management network (192.168.1.0/24).

**Why a self-hosted runner on the hypervisor?**  
GitHub's cloud runners (ubuntu-latest) run in GitHub's datacentre. They have no network
path to the VMs inside the hypervisor's private networks. A self-hosted runner on the
hypervisor has direct SSH access to `192.168.1.10` (cp-01) and `192.168.1.20/.30`
(w-01, w-02) without any VPN, tunnel, or port forwarding.

---

### 8.2 Three-Stage Pipeline

**Stage 1 — Build:**
```
docker build → docker run (unit test) → docker save | gzip → upload artifact
```
All three images are built with the git commit SHA as the tag. A backend unit test runs
inside the freshly built container to catch regressions before any image reaches the
cluster.

**Stage 2 — Transfer:**
```
Download artifact → write SSH key → ssh-keyscan → scp to nodes → ctr images import
```
> **Definition — `ctr images import`**  
> `ctr` is the containerd CLI. `ctr images import <tarball>` loads a Docker-format
> image tarball directly into containerd's image store without needing a registry.

**Why `ctr import` instead of a container registry?**  
A container registry (Docker Hub, GitHub Container Registry, private registry) would
require either: (a) internet access from the cluster nodes to pull images, or (b) a
private registry VM added to the infrastructure. The cluster nodes are on a private
network with no internet access. `docker save | gzip | scp | ctr import` bypasses the
registry entirely — the runner builds locally, transfers directly over SSH, and imports
into containerd on each node.

**Stage 3 — Deploy:**
```
Decode KUBE_CONFIG → kubectl apply → rollout status → health check → (on failure) rollout undo
```

---

### 8.3 Security Decisions in the Pipeline

**`StrictHostKeyChecking=yes` + `ssh-keyscan`:**  
`StrictHostKeyChecking=no` disables host key verification entirely — a connection to a
wrong or spoofed server would succeed silently. `StrictHostKeyChecking=yes` refuses
connections to hosts not in `known_hosts`. The pipeline runs `ssh-keyscan` first to
populate `known_hosts` with the legitimate host keys, then uses `StrictHostKeyChecking=yes`
to ensure every subsequent SSH/SCP connection is to the expected host.

**Secret guard — `kubectl get secret || kubectl apply`:**
```bash
kubectl get secret bmi-secrets -n production >/dev/null 2>&1 || \
  kubectl apply -f .../02-secret.yaml
```
This one-liner makes the secret application *idempotent but not overwriting*. On the
first deploy, the secret does not exist so it is created. On all subsequent deploys,
the existing secret is left untouched. Without this guard, every CI/CD run would
overwrite the secret with the repository version — losing any operator updates (for
example, a new `DATABASE_URL` set during Runbook 6.5 failover to db-01).

**Image tag strategy — git commit SHA:**  
Using `${{ github.sha }}` as the image tag ensures every build is unique and traceable.
`latest` is never used because it is mutable — `kubectl rollout undo` would have no
stable previous version to return to. With SHA tags, rolling back is always to a
specific, reproducible build.

---

## 9. Cross-Phase Design Principles

### 9.1 Immutable Infrastructure

Every VM is provisioned from a base Ubuntu 24.04 cloud image plus cloud-init.
No VM is ever manually modified after provisioning — configuration changes are made in
cloud-init YAML, Terraform HCL, or Kubernetes manifests, then re-applied. If a VM
is broken, it is destroyed and re-provisioned: `terraform apply -target=libvirt_domain.vms["<name>"]`.

### 9.2 Version Pinning

Every image, tool, and package is pinned to a specific version. Unpinned versions
(`latest`, `*`, `^`) make deployments non-reproducible — the same `kubectl apply` run
on different days may produce different results. This project pins:
- Kubernetes: v1.32
- All container images: specific tags (e.g., `grafana/loki:3.1.0`)
- Terraform provider: `~> 0.8.1` (patch updates only)
- nfs-subdir-external-provisioner: `v4.0.2`

### 9.3 GitOps Principles

Every component of the system — infrastructure (Terraform HCL), VM configuration
(cloud-init YAML), and application configuration (Kubernetes manifests) — lives in
version-controlled files. The desired state is always readable from the repository.
The CI/CD pipeline applies manifest changes automatically on push to `main`.

The one exception is `terraform.tfvars` (generated at runtime with SSH keys) — this
is correctly excluded from version control via `.gitignore`.

### 9.4 Separation of Concerns

| Concern | Where handled |
|---------|--------------|
| Infrastructure provisioning | Terraform + cloud-init (Phase 1) |
| Cluster bootstrapping | kubeadm + Cilium (Phase 2) |
| Application workloads | Kubernetes manifests (Phase 3) |
| Observability | Prometheus/Grafana/Loki stack (Phase 4) |
| Security enforcement | PSA, RBAC, NetworkPolicies, UFW (Phase 5) |
| Operational procedures | Runbooks (Phase 6) |
| Change delivery | GitHub Actions CI/CD (Phase 7) |

Each phase is independently applicable and independently understandable. A team member
can understand Phase 3 (application manifests) without needing to understand Terraform.

---

## 10. Glossary

| Term | Definition |
|------|-----------|
| **API Server** | The central Kubernetes control-plane component that exposes the Kubernetes API over HTTPS |
| **CRI** | Container Runtime Interface — the gRPC API that kubelet uses to talk to a container runtime |
| **CronJob** | Kubernetes workload that creates Jobs on a time-based schedule (cron syntax) |
| **DaemonSet** | Kubernetes workload ensuring one pod runs on every (or selected) cluster node |
| **Deployment** | Kubernetes workload managing stateless pod replicas with rolling update support |
| **eBPF** | Extended Berkeley Packet Filter — runs sandboxed kernel programs for networking, tracing, security |
| **etcd** | Distributed key-value store used as Kubernetes' backing store for all cluster data |
| **HPA** | HorizontalPodAutoscaler — automatically scales pod replicas based on CPU/memory metrics |
| **IaC** | Infrastructure as Code — managing infrastructure through machine-readable definition files |
| **KIC** | Kong Ingress Controller — Kubernetes-native deployment of the Kong API gateway |
| **KVM** | Kernel-based Virtual Machine — Linux kernel hypervisor using hardware virtualisation extensions |
| **kubeadm** | CNCF tool for bootstrapping a production Kubernetes cluster |
| **kubelet** | Primary node agent; ensures containers described in pod specs are running and healthy |
| **LimitRange** | Namespace-level resource policy that injects default CPU/memory limits into containers |
| **Loki** | Log aggregation system that indexes only labels (not content) for low-overhead log storage |
| **NetworkPolicy** | Kubernetes resource specifying allowed ingress/egress traffic for a set of pods |
| **NFS** | Network File System — distributed file-sharing protocol; provides ReadWriteMany PVCs here |
| **NodePort** | Service type that opens a port on every cluster node for external traffic ingress |
| **PGDG** | PostgreSQL Global Development Group — official apt repository for PostgreSQL packages |
| **Pod** | The smallest deployable unit in Kubernetes; one or more containers sharing network and storage |
| **Prometheus** | Open-source monitoring system using a pull model to scrape time-series metrics |
| **Promtail** | Loki's log collection agent; runs as a DaemonSet to tail pod logs on each node |
| **PSA** | Pod Security Admission — built-in admission controller enforcing pod security standards |
| **PV** | PersistentVolume — a piece of cluster storage provisioned by an administrator or StorageClass |
| **PVC** | PersistentVolumeClaim — a request for storage that binds to a PV |
| **RBAC** | Role-Based Access Control — Kubernetes mechanism controlling access to API resources |
| **ResourceQuota** | Namespace-level cap on total CPU, memory, pod count, and PVC count |
| **RPO** | Recovery Point Objective — maximum acceptable data loss in time (here: 24 hours) |
| **RTO** | Recovery Time Objective — maximum acceptable time to restore service (here: 30 minutes) |
| **SA** | ServiceAccount — identity for pods to authenticate to the Kubernetes API server |
| **StatefulSet** | Kubernetes workload for stateful applications requiring stable identity and per-replica PVCs |
| **StorageClass** | Template that defines how PVCs are dynamically provisioned by a storage backend |
| **Terraform** | Open-source IaC tool that provisions and manages infrastructure via provider plugins |
| **UFW** | Uncomplicated Firewall — Ubuntu CLI wrapper for iptables/nftables host-level packet filtering |
| **cloud-init** | Industry standard for VM instance initialisation on first boot via user-data YAML |
| **containerd** | CRI-compliant container runtime used by Kubernetes to run containers |
| **libvirt** | Virtualisation management API and daemon for KVM/QEMU and other hypervisors |
| **kubeProxyReplacement** | Cilium mode where Cilium's eBPF fully replaces kube-proxy for service routing |

---

*Document generated for agk Technical Assessment — IT Operations Officer role.*  
*Repository: `f:/PROJECT` | Last updated: 2026-06-23*
