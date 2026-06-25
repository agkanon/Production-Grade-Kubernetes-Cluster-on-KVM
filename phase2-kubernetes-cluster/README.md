# Phase 2: Kubernetes Cluster Setup

 — agk Technical Assessment  
**Status**: Complete (manual execution)  
**Prerequisites**: Phase 1 KVM infrastructure deployed and all 6 VMs running

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                     Kubernetes Cluster                              │
│                                                                     │
│   ┌─────────────────────────────────────────────────────────────┐  │
│   │            Control Plane  cp-01 · 192.168.1.10             │  │
│   │   etcd · API Server :6443 · Scheduler · Controller-Manager │  │
│   └─────────────────────────────────────────────────────────────┘  │
│                               │                                     │
│              ┌────────────────┴────────────────┐                   │
│              │                                 │                   │
│   ┌──────────▼──────────┐         ┌────────────▼────────────┐     │
│   │  Worker  w-01        │         │  Worker  w-02           │     │
│   │  192.168.1.20        │         │  192.168.1.30           │     │
│   └─────────────────────┘         └─────────────────────────┘     │
│              │                                 │                   │
│   ┌──────────▼─────────────────────────────────▼────────────┐     │
│   │         Cilium eBPF Pod Network  10.244.0.0/16           │     │
│   │         Service Network          10.96.0.0/12            │     │
│   └──────────────────────────────────────────────────────────┘     │
│                                                                     │
│   ┌──────────────────────────────────────────────────────────┐     │
│   │   Persistent Storage — NFS (Option A)                   │     │
│   │   Server: nfs-01 · 192.168.2.40:/nfs/kubernetes  50 GB  │     │
│   │   StorageClass: nfs-client (default)                     │     │
│   └──────────────────────────────────────────────────────────┘     │
│                                                                     │
│   ┌──────────────────────────────────────────────────────────┐     │
│   │   Namespaces: production · monitoring · kong             │     │
│   │   Network Policies: default-deny + tier-specific allow   │     │
│   │   ResourceQuota + LimitRange + PodDisruptionBudget       │     │
│   └──────────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

Verify Phase 1 is complete before proceeding:

```bash
# All 6 VMs running
cat >> ~/.bashrc << 'EOF'

virsh-list() {
  echo " Id   Name       State       IP Address"
  echo "----------------------------------------------"
  virsh list --all | awk 'NR>2 && $2!=""' | while read id name state; do
    mac=$(virsh domiflist $name 2>/dev/null | awk 'NR>2 && $1!="" {print $5}' | head -1)
    ip=$(ip neigh show | grep -i "$mac" | awk '{print $1}')
    printf " %-4s %-10s %-12s %s\n" "$id" "$name" "$state" "${ip:-N/A}"
  done
}
EOF
source ~/.bashrc

virsh-list

sudo chown -R ubuntu phase1-kvm-infrastructure/.ssh/
# SSH reachable
ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.10 "hostname"
ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.20 "hostname"
ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.30 "hostname"
ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.40 "hostname"

# containerd running on Kubernetes nodes
ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.10 \
  "sudo systemctl is-active containerd kubelet"

# kubeadm installed
ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.10 \
  "kubeadm version --output short"
```

**Expected**: All VMs running, SSH responding, containerd active, kubeadm present.

---

## Task 2.1 — Initialise the Cluster

### Why kubeadm?

`kubeadm` is the CNCF-endorsed standard bootstrapping tool for production Kubernetes.
It handles TLS certificate generation, etcd bootstrap, control-plane static-pod
manifests, and worker join tokens in one auditable workflow — without the hidden
abstractions of managed installers (k3s, microk8s). Every configuration flag is
explicit and defensible in a technical review.

### Why Cilium as the CNI plugin?

| Criterion | Cilium | Calico | Flannel |
|-----------|--------|--------|---------|
| Dataplane | eBPF (kernel-native) | iptables / eBPF optional | iptables |
| NetworkPolicy | Full L3–L7 | L3–L4 | None |
| Performance | Highest (bypasses netfilter) | Good | Good |
| Observability | Hubble built-in | Add-on | None |
| kube-proxy replacement | Yes | Partial | No |
| Production readiness | CNCF Graduated | CNCF Graduated | Stable |

**Decision**: Cilium is chosen because this cluster must enforce NetworkPolicies for
tier isolation (required by Task 2.4). Cilium's eBPF dataplane also replaces
kube-proxy entirely, reducing iptables rule sprawl and improving throughput on the
KVM nodes. Flannel was ruled out (no NetworkPolicy). Calico would work but requires
an additional eBPF patch to match Cilium's out-of-the-box performance on
kernel 5.15+ (Ubuntu 24.04's default).

---

### Step 1 — Connect to the Control Plane

```bash
ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.10
```

### Step 2 — Pre-flight checks

```bash
# Verify containerd and kubelet
sudo systemctl status containerd
sudo systemctl start kubelet
sudo systemctl status kubelet   # Expected: activating or failed — normal before init

# Confirm kubeadm, kubelet, kubectl versions match
kubeadm version
kubelet --version
kubectl version --client
```

### Step 3 — Initialise the Control Plane

```bash
sudo kubeadm init \
  --apiserver-advertise-address=192.168.1.10 \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --control-plane-endpoint=192.168.1.10:6443 \
  --token-ttl=24h \
  --upload-certs \
  --v=2
```

**Parameter rationale:**

| Flag | Value | Why |
|------|-------|-----|
| `--apiserver-advertise-address` | 192.168.1.10 | Management NIC — storage and external NICs must not carry API traffic |
| `--pod-network-cidr` | 10.244.0.0/16 | Required by Cilium's IPAM; must not overlap host or service CIDRs |
| `--service-cidr` | 10.96.0.0/12 | Standard Kubernetes default; gives 1 M+ ClusterIP addresses |
| `--control-plane-endpoint` | 192.168.1.10:6443 | HAProxy on lb-01 fronts this; single stable endpoint for workers |
| `--token-ttl` | 24h | Short-lived token — workers must join within the window |
| `--upload-certs` | — | Uploads encrypted certs to etcd so a second control plane can join without manual cert transfer |

**Save the output.** kubeadm prints:
1. The worker join command (needed in Task 2.2)
2. The certificate key (needed if adding a second control plane)

> **Note**: If the initial join command is lost or the token later expires, you can
> generate a fresh one at any time from the control plane:
> ```bash
> kubeadm token create --print-join-command
> ```
> The deploy script uses this approach because it is more reliable than parsing the
> multi-line `kubeadm init` output.

### Step 4 — Configure kubectl

```bash
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Verify API server is reachable
kubectl cluster-info
# Expected: Kubernetes control plane is running at https://192.168.1.10:6443
```

### Step 5 — Install Cilium CNI

```bash
# Install Cilium CLI (run on cp-01)
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --remote-name-all \
  "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz"
sudo tar -C /usr/local/bin -xzf cilium-linux-amd64.tar.gz
rm cilium-linux-amd64.tar.gz

# Install Cilium into the cluster
cilium install \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=192.168.1.10 \
  --set k8sServicePort=6443

# Wait for Cilium to be ready (2-3 minutes)
cilium status --wait

# Remove kube-proxy — kubeadm deploys it by default; with kubeProxyReplacement=true
# both would manage iptables/eBPF rules simultaneously, causing routing conflicts
kubectl delete -n kube-system daemonset kube-proxy
kubectl delete -n kube-system configmap kube-proxy
```

**Flag rationale:**

| Flag | Why |
|------|-----|
| `ipam.mode=kubernetes` | Delegates pod IP allocation to Kubernetes; honours `--pod-network-cidr` set at init |
| `kubeProxyReplacement=true` | Fully replaces kube-proxy with eBPF; eliminates iptables rule chains on each node |
| `k8sServiceHost/Port` | Required when kube-proxy is replaced — Cilium needs to know where the API server is |

### Task 2.1 Verification

```bash
# All nodes NotReady → Ready after Cilium starts
kubectl get nodes -o wide
# Expected:
# NAME    STATUS   ROLES           AGE   VERSION
# cp-01   Ready    control-plane   Xm    v1.32.x

# All control-plane system pods Running
kubectl get pods -n kube-system

# Cilium DaemonSet running (1 pod on cp-01 at this point)
kubectl get pods -n kube-system -l k8s-app=cilium

# Cilium health check
cilium status
# Expected: all indicators OK/disabled

# Pod-to-pod connectivity test
kubectl create namespace test-cni
kubectl run p1 --image=busybox:1.37 -n test-cni -- sleep 600
kubectl run p2 --image=busybox:1.37 -n test-cni -- sleep 600
kubectl wait --for=condition=Ready pod/p1 pod/p2 -n test-cni --timeout=60s
P1_IP=$(kubectl get pod p1 -n test-cni -o jsonpath='{.status.podIP}')
kubectl exec p2 -n test-cni -- ping -c 3 $P1_IP
kubectl delete namespace test-cni
```

---

## Task 2.2 — Join the Worker Nodes

### Step 1 — Retrieve the join command (on cp-01)

```bash
# Generate a fresh join token — more reliable than re-parsing init output
kubeadm token create --print-join-command
```

Copy the full output — it looks like:
```
kubeadm join 192.168.1.10:6443 --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

> **Why generate a fresh token?** The token printed by `kubeadm init` may expire
> (`--token-ttl=24h`) before you reach this step. Using `kubeadm token create
> --print-join-command` guarantees a valid token and avoids parsing multi-line
> init output.

### Step 2 — Join Worker 1

```bash
ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.20

# Paste the join command from Step 1
sudo kubeadm join 192.168.1.10:6443 --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --v=2

exit
```

### Step 3 — Join Worker 2

```bash
ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.30

sudo kubeadm join 192.168.1.10:6443 --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --v=2

exit
```

### Step 4 — Apply node labels (on cp-01)

Labels enable workload scheduling rules — the scheduler can constrain Pods to
specific node roles using `nodeSelector` or `nodeAffinity`.

```bash
# Worker role label (the default <none> is not descriptive)
kubectl label node w-01 node-role.kubernetes.io/worker=worker
kubectl label node w-02 node-role.kubernetes.io/worker=worker

# Workload-type labels for affinity rules in Phase 3
kubectl label node w-01 workload=application
kubectl label node w-02 workload=application

# Verify labels
kubectl get nodes --show-labels
```

### Task 2.2 Verification

```bash
kubectl get nodes -o wide
# Expected — all three nodes Ready:
# NAME    STATUS   ROLES           VERSION
# cp-01   Ready    control-plane   v1.32.x
# w-01    Ready    worker          v1.32.x
# w-02    Ready    worker          v1.32.x

# Cilium DaemonSet now has 3 pods (one per node)
kubectl get pods -n kube-system -l k8s-app=cilium -o wide

# Run connectivity test across nodes
cilium connectivity test --test-namespace cilium-test
kubectl delete namespace cilium-test --ignore-not-found
```

---

## Task 2.3 — Persistent Storage (NFS — Option A)

### Why NFS over a Distributed Backend (Option B)?

| Criterion | NFS (Option A) | Longhorn / Rook-Ceph (Option B) |
|-----------|---------------|----------------------------------|
| Complexity | Low — single dedicated VM | High — multi-node distributed system |
| Resource overhead | Minimal | High (OSDs, monitors, managers) |
| Setup time | 15 minutes | 60–90 minutes |
| Redundancy | Single-server (mitigated by VM snapshots) | Built-in replication |
| ReadWriteMany | Native | Requires CephFS |
| Suitable for assessment scale | Yes | Over-engineered |

**Decision**: A dedicated `nfs-01` VM (192.168.1.40, 50 GB disk) already exists from
Phase 1 and exports `/nfs/kubernetes`. The `nfs-subdir-external-provisioner` gives
dynamic PVC provisioning with a StorageClass, satisfying the assessment requirement.
A distributed backend would add operational complexity without meaningful benefit at
this scale — Phase 4 would be the right place to introduce Longhorn for HA.

### Step 1 — Verify (or set up) NFS server on nfs-01

The Phase 1 cloud-init may have pre-installed nfs-kernel-server. If not, install and
configure it now:

```bash
ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.40

# Install NFS server if not already present
sudo apt-get install -y nfs-kernel-server -qq

# Create the export directory
sudo mkdir -p /nfs/kubernetes
sudo chown nobody:nogroup /nfs/kubernetes
sudo chmod 755 /nfs/kubernetes

# Configure the export
echo '/nfs/kubernetes 192.168.2.0/24(rw,sync,no_subtree_check,no_root_squash,insecure)' \
  | sudo tee /etc/exports

# Start and enable the service
sudo systemctl enable nfs-server
sudo systemctl restart nfs-server

# Verify
sudo systemctl is-active nfs-server
# Expected: active

sudo exportfs -v
# Expected: /nfs/kubernetes  192.168.2.0/24(rw,...)

df -h /nfs/kubernetes
# Expected: ~50 GB available

exit
```

### Step 2 — Install NFS client on all Kubernetes nodes

Run on **cp-01, w-01, w-02** (repeat for each):

```bash
# Example for cp-01
ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.10
sudo apt-get install -y nfs-common
exit

ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.20
sudo apt-get install -y nfs-common
exit

ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.30
sudo apt-get install -y nfs-common
exit
```

### Step 3 — Test NFS mount from each worker

```bash
# On w-01
ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.20
sudo mkdir -p /mnt/nfs-test
sudo mount -t nfs 192.168.2.40:/nfs/kubernetes /mnt/nfs-test
df -h /mnt/nfs-test    # Must show the 50 GB share
sudo umount /mnt/nfs-test
exit

# On w-02
ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.30
sudo mkdir -p /mnt/nfs-test
sudo mount -t nfs 192.168.2.40:/nfs/kubernetes /mnt/nfs-test
df -h /mnt/nfs-test
sudo umount /mnt/nfs-test
exit
```

### Step 4 — Deploy NFS Subdir External Provisioner (on cp-01)

```bash
ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.10
mkdir -p $HOME/manifests/storage
cd $HOME/manifests/storage
```

**4a. RBAC**

```bash
cat > nfs-rbac.yaml <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: nfs-provisioner
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: nfs-provisioner
rules:
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get","list","watch","create","delete"]
  - apiGroups: [""]
    resources: ["persistentvolumeclaims"]
    verbs: ["get","list","watch","update"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get","list","watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["create","update","patch"]
  - apiGroups: [""]
    resources: ["endpoints"]
    verbs: ["get","list","watch","create","update","patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: nfs-provisioner
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: nfs-provisioner
subjects:
  - kind: ServiceAccount
    name: nfs-provisioner
    namespace: kube-system
EOF

kubectl apply -f nfs-rbac.yaml
```

**4b. Provisioner Deployment**

```bash
cat > nfs-provisioner.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nfs-provisioner
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nfs-provisioner
  strategy:
    type: Recreate
  template:
    metadata:
      labels:
        app: nfs-provisioner
    spec:
      serviceAccountName: nfs-provisioner
      containers:
        - name: nfs-provisioner
          image: registry.k8s.io/sig-storage/nfs-subdir-external-provisioner:v4.0.2
          env:
            - name: PROVISIONER_NAME
              value: nfs.io/nfs-client
            - name: NFS_SERVER
              value: "192.168.2.40"
            - name: NFS_PATH
              value: /nfs/kubernetes
          volumeMounts:
            - name: nfs-root
              mountPath: /persistentvolumes
      volumes:
        - name: nfs-root
          nfs:
            server: 192.168.2.40
            path: /nfs/kubernetes
EOF

kubectl apply -f nfs-provisioner.yaml
kubectl rollout status deployment/nfs-provisioner -n kube-system --timeout=60s
```

**4c. StorageClass**

```bash
cat > nfs-storageclass.yaml <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: nfs.io/nfs-client
parameters:
  archiveOnDelete: "false"
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF

kubectl apply -f nfs-storageclass.yaml
kubectl get storageclass
# Expected: nfs-client (default)
```

### Task 2.3 Verification — Dynamic PVC provisioning

```bash
cat > nfs-test-pvc.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: nfs-test-pvc
  namespace: default
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: nfs-client
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: nfs-test-pod
  namespace: default
spec:
  containers:
    - name: writer
      image: busybox:1.37
      command: ["sh","-c","echo 'NFS OK' > /data/probe.txt && sleep 30"]
      volumeMounts:
        - name: vol
          mountPath: /data
  volumes:
    - name: vol
      persistentVolumeClaim:
        claimName: nfs-test-pvc
  restartPolicy: Never
EOF

kubectl apply -f nfs-test-pvc.yaml
kubectl wait --for=condition=Ready pod/nfs-test-pod --timeout=60s

# PVC must be Bound
kubectl get pvc nfs-test-pvc
# STATUS must be: Bound

# Data written to NFS share
kubectl exec nfs-test-pod -- cat /data/probe.txt
# Expected: NFS OK

# Cleanup
kubectl delete -f nfs-test-pvc.yaml
```

---

## Task 2.4 — Cluster Networking & Security

This task implements three controls required by the assessment:
1. **Namespaces** — create the project namespaces with correct labels before any workload lands
2. **NetworkPolicies** — zero-trust tier isolation explained here; Phase 5 applies the manifests after pods exist
3. **ResourceQuota + LimitRange** — namespace-level CPU/memory governance
4. **PodDisruptionBudgets** — minimum availability during node maintenance

### Step 1 — Create project namespaces

The cluster uses three namespaces. Creating them here (with their labels) ensures
Phase 3, Phase 4, and Phase 5 can all reference them without a bootstrap ordering problem.

```bash
# Create all three project namespaces
kubectl create namespace production
kubectl create namespace monitoring
kubectl create namespace kong

# Apply the well-known kubernetes.io/metadata.name label to each namespace.
# NetworkPolicy namespaceSelectors match on this label — it must be present
# before any NetworkPolicy that references the namespace is applied.
kubectl label namespace production  kubernetes.io/metadata.name=production
kubectl label namespace monitoring  kubernetes.io/metadata.name=monitoring
kubectl label namespace kong        kubernetes.io/metadata.name=kong

kubectl get namespaces --show-labels
# Expected: production, monitoring, kong each with kubernetes.io/metadata.name=<name>
```

### Step 2 — NetworkPolicy pattern (zero-trust tier isolation)

**Why default-deny first?**  
Kubernetes has no implicit isolation — without a NetworkPolicy every pod can reach
every other pod across every namespace. The pattern below starts from a zero-trust
baseline (deny all ingress AND egress), then opens only the specific paths the
3-tier architecture requires. A compromised frontend pod can never directly query
the database even if an attacker exploits it.

**How the tiers communicate** (all pods live in the `production` namespace, separated
by `tier:` labels):

```
Internet → HAProxy → Kong (kong ns) ─── port 80  → tier:frontend
                                    └── port 3000 → tier:backend
                                                         │
                                                    port 5432
                                                         ↓
                                                   tier:database (postgres)
```

**Why NetworkPolicies are applied in Phase 5, not here:**  
Phase 5 (`phase5-security-hardening/manifests/04-network-policies.yaml`) contains
the complete, ready-to-apply manifest set. Applying default-deny in Phase 2 before
Phase 3 deploys pods would block the application from starting. The correct order is:
deploy the app first (Phase 3), then lock it down (Phase 5). The policies shown
below are for understanding — Phase 5 applies them.

**Tier-isolation policy summary:**

| Policy | Namespace | Allows |
|--------|-----------|--------|
| `default-deny-all` | production | Nothing (baseline) |
| `allow-dns-egress` | production | All pods → kube-dns :53 (UDP+TCP) |
| `frontend-policy` | production | kong-ns → `tier:frontend` :80 |
| `backend-policy` | production | kong-ns → `tier:backend` :3000; monitoring-ns → :3000; backend → postgres :5432 |
| `postgres-policy` | production | `tier:backend` → :5432; `app:pg-backup` → :5432 |
| `allow-kong-to-production` | production | kong-ns → `tier:frontend` :80 |

The use of `kubernetes.io/metadata.name` in `namespaceSelector` (rather than a
custom label) ensures policies cannot be circumvented by relabelling a namespace —
this label is set and enforced by the API server and cannot be overridden by users
without cluster-admin rights.

Phase 5 manifests are in `phase5-security-hardening/manifests/04-network-policies.yaml`.

### Step 3 — ResourceQuotas and LimitRanges

**Why both?**
- `ResourceQuota` caps the *total* resources a namespace can consume — prevents the
  monitoring stack from starving application pods during a metrics scrape surge.
- `LimitRange` injects *per-container* defaults — any pod that omits resource fields
  gets sensible defaults automatically. This is required when a ResourceQuota is active
  because Kubernetes rejects pods with no resource spec if a quota exists.

**Resource sizing rationale for `production`:**

| Workload | Replicas | CPU request | Mem request |
|----------|----------|-------------|-------------|
| backend Deployment | 2 | 100m each | 128Mi each |
| frontend Deployment | 2 | 50m each | 64Mi each |
| postgres StatefulSet | 1 | 250m | 256Mi |
| pg-backup CronJob | 0–1 | 50m | 64Mi |
| **Total** | | **~600m** | **~704Mi** |

Quota is set at 3× steady-state to allow rolling-update surge pods and CronJob concurrency.

```bash
ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.10
mkdir -p $HOME/manifests/governance
cd $HOME/manifests/governance

cat > resource-quotas.yaml <<'EOF'
# ── production namespace quota ──────────────────────────────────────
# Headroom: 3× steady-state for rolling updates and CronJob concurrency.
apiVersion: v1
kind: ResourceQuota
metadata:
  name: production-quota
  namespace: production
spec:
  hard:
    requests.cpu: "2"
    requests.memory: 2Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "15"
    persistentvolumeclaims: "5"
---
# ── monitoring namespace quota ──────────────────────────────────────
# Prometheus (1) + Node Exporter DaemonSet (3) + Grafana (1) + Loki (1) + Promtail DaemonSet (3) = 9 pods max
apiVersion: v1
kind: ResourceQuota
metadata:
  name: monitoring-quota
  namespace: monitoring
spec:
  hard:
    requests.cpu: "1"
    requests.memory: 1Gi
    limits.cpu: "4"
    limits.memory: 4Gi
    pods: "15"
    persistentvolumeclaims: "5"
EOF

kubectl apply -f resource-quotas.yaml
kubectl describe resourcequota -n production
kubectl describe resourcequota -n monitoring
```

```bash
cat > limit-ranges.yaml <<'EOF'
# ── production LimitRange ───────────────────────────────────────────
# Defaults applied to containers that omit resource fields.
apiVersion: v1
kind: LimitRange
metadata:
  name: container-limits
  namespace: production
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      default:
        cpu: 500m
        memory: 512Mi
      max:
        cpu: "2"
        memory: 2Gi
      min:
        cpu: 50m
        memory: 64Mi
---
# ── monitoring LimitRange ───────────────────────────────────────────
apiVersion: v1
kind: LimitRange
metadata:
  name: container-limits
  namespace: monitoring
spec:
  limits:
    - type: Container
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      default:
        cpu: 500m
        memory: 512Mi
      max:
        cpu: "2"
        memory: 2Gi
      min:
        cpu: 50m
        memory: 64Mi
EOF

kubectl apply -f limit-ranges.yaml
kubectl get limitrange --all-namespaces
```

### Step 4 — PodDisruptionBudgets

**Why PDBs?**  
During a `kubectl drain` (node maintenance, rolling upgrade, or node failure recovery),
the eviction API honours PDBs — it will not evict a pod if doing so would drop the
number of running replicas below `minAvailable`. Without PDBs a drain can take every
replica of a Deployment offline simultaneously, causing a full service outage.

The frontend and backend Deployments each run 2 replicas (Phase 3). A `minAvailable: 1`
PDB ensures at least one replica stays running during any single disruption event.
PostgreSQL is a single-replica StatefulSet — draining its node requires manual
intervention regardless (PDB has no effect on single-replica workloads in practice,
but is included for completeness).

```bash
cat > pod-disruption-budgets.yaml <<'EOF'
# ── frontend PDB ─────────────────────────────────────────────────────
# 2 replicas → minAvailable 1 means drain can proceed one pod at a time.
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: frontend-pdb
  namespace: production
spec:
  minAvailable: 1
  selector:
    matchLabels:
      tier: frontend
---
# ── backend PDB ──────────────────────────────────────────────────────
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: backend-pdb
  namespace: production
spec:
  minAvailable: 1
  selector:
    matchLabels:
      tier: backend
---
# ── postgres PDB ─────────────────────────────────────────────────────
# Single-replica StatefulSet. PDB signals intent to the drain process
# even though 1 replica means any eviction disrupts the database.
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: postgres-pdb
  namespace: production
spec:
  minAvailable: 1
  selector:
    matchLabels:
      tier: database
EOF

kubectl apply -f pod-disruption-budgets.yaml
```

### Task 2.4 Verification

```bash
# Namespaces with correct labels
kubectl get namespaces production monitoring kong --show-labels
# Each must have kubernetes.io/metadata.name=<name>

# ResourceQuotas active (no pods yet — Used values will be 0)
kubectl describe resourcequota production-quota -n production
kubectl describe resourcequota monitoring-quota -n monitoring

# LimitRanges applied
kubectl get limitrange -n production
kubectl get limitrange -n monitoring

# PDBs configured (Allowed Disruptions will show 0 until pods are deployed)
kubectl get poddisruptionbudgets -n production
# Expected: frontend-pdb, backend-pdb, postgres-pdb
```

---

## Full Cluster Verification

Run this end-to-end checklist after completing all four tasks:

```bash
# ── Nodes ───────────────────────────────────────────────────────────
kubectl get nodes -o wide
# All three nodes: STATUS=Ready
# NAME    STATUS   ROLES           VERSION
# cp-01   Ready    control-plane   v1.32.x
# w-01    Ready    worker          v1.32.x
# w-02    Ready    worker          v1.32.x

# ── System pods ─────────────────────────────────────────────────────
kubectl get pods -n kube-system
# All Running: etcd, kube-apiserver, kube-scheduler,
#              kube-controller-manager, coredns, cilium, cilium-operator,
#              nfs-provisioner
# kube-proxy must NOT appear — it was deleted after Cilium install

# ── Storage ─────────────────────────────────────────────────────────
kubectl get storageclass
# nfs-client (default)

kubectl get deployment nfs-provisioner -n kube-system
# 1/1 Ready

# ── Networking ──────────────────────────────────────────────────────
cilium status
# All indicators OK

# No NetworkPolicies yet — they are applied in Phase 5 after pods exist
kubectl get networkpolicies --all-namespaces
# Expected: No resources found (correct at this stage)

# ── Namespaces ──────────────────────────────────────────────────────
kubectl get namespaces production monitoring kong --show-labels
# All three present with kubernetes.io/metadata.name=<name> label

# ── Resource management ─────────────────────────────────────────────
kubectl get resourcequota --all-namespaces
# production-quota and monitoring-quota present

kubectl get limitrange --all-namespaces
# container-limits in production and monitoring

kubectl get poddisruptionbudgets -n production
# frontend-pdb, backend-pdb, postgres-pdb
# (Allowed Disruptions = 0 until Phase 3 pods are running — this is correct)
```

---

## Task 2.5 — Metrics Server (Required for HPA)

The Horizontal Pod Autoscaler (Phase 3, `05-frontend.yaml`) queries the Metrics
Server for live CPU utilisation. Without it, HPA shows `<unknown>` and never scales.

### Why Metrics Server instead of full Prometheus?

Metrics Server is the Kubernetes-native, lightweight source for HPA and `kubectl top`.
It scrapes kubelet's summary API — not a full monitoring backend. Prometheus (Phase 4)
complements it for dashboards and alerting but cannot replace Metrics Server for HPA.

### Install Metrics Server

```bash
# On cp-01
# Download the manifest — the --kubelet-insecure-tls flag is required
# on bare-metal/KVM clusters where kubelet certificates are self-signed
curl -LO https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# Patch the Deployment to skip TLS verification (bare-metal requirement)
sed -i '/--metric-resolution/a\        - --kubelet-insecure-tls' components.yaml

kubectl apply -f components.yaml
```

### Verify Metrics Server is ready

```bash
kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s

# Node and pod metrics must be available
kubectl top nodes
# Expected:
# NAME    CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
# cp-01   120m         3%     900Mi           23%
# w-01    80m          2%     750Mi           19%
# w-02    75m          1%     720Mi           18%

kubectl top pods -n kube-system
```

---

## Troubleshooting

### Nodes remain NotReady after kubeadm init

```bash
# Check kubelet for errors
journalctl -u kubelet -n 50 --no-pager

# Confirm containerd socket exists
ls -la /run/containerd/containerd.sock

# Cilium DaemonSet pods crashing?
kubectl describe pod -n kube-system -l k8s-app=cilium
```

### Cilium pods CrashLoopBackOff

```bash
kubectl logs -n kube-system -l k8s-app=cilium --previous

# Most common cause: kernel < 5.10 — check
uname -r
# Ubuntu 24.04 ships 6.x — this should not occur
```

### NFS mount fails from worker nodes

```bash
# Confirm NFS server is exporting
ssh ubuntu@192.168.1.40 "sudo exportfs -v"

# Confirm port 2049 reachable from worker
ssh ubuntu@192.168.1.20 "nc -zv 192.168.2.40 2049"

# Check nfs-common installed
ssh ubuntu@192.168.1.20 "dpkg -l nfs-common"
```

### PVC stuck in Pending

```bash
# Check provisioner logs
kubectl logs -n kube-system deployment/nfs-provisioner

# Confirm StorageClass name matches PVC spec
kubectl get storageclass
kubectl describe pvc <name>
```

### Network policy blocking expected traffic

```bash
# Temporarily remove default-deny to isolate
kubectl delete networkpolicy default-deny-ingress -n <namespace>

# Use Cilium policy tracing
kubectl exec -n kube-system ds/cilium -- \
  cilium policy trace --src-k8s-pod frontend/<pod> --dst-k8s-pod backend/<pod>

# Reapply after confirming labels match policy selectors
```

---

## Next Step

Phase 2 complete. Proceed to **Phase 3 — Application Deployment**  
(`phase3-application-deployment/`).

Place Dockerfiles and application source code in:
- `phase3-application-deployment/frontend/`
- `phase3-application-deployment/backend/`
- `phase3-application-deployment/database/`

Kubernetes manifests will be added to `phase3-application-deployment/manifests/`.

---

**Project**: agk Technical Assessment — Production-Grade Kubernetes on KVM  
**Phase**: 2 — Kubernetes Cluster Setup  
