# Phase 6: Operations Runbooks

 — agk Technical Assessment  
**Scope**: Day-2 operational procedures for the BMI Health Tracker Kubernetes cluster  
**Audience**: On-call engineers, cluster administrators

---

## Runbook Index

| # | Runbook | Estimated Time |
|---|---------|---------------|
| [6.1](#runbook-61--add-a-worker-node) | Add a worker node | 15 min |
| [6.2](#runbook-62--remove-a-worker-node) | Remove a worker node | 20 min |
| [6.3](#runbook-63--rolling-application-update) | Rolling application update | 10 min |
| [6.4](#runbook-64--database-restore-from-pg_dump-backup) | Database restore from pg_dump backup | 20 min |
| [6.5](#runbook-65--emergency-failover-to-db-01-vm) | Emergency failover to db-01 VM | 30 min |
| [6.6](#runbook-66--cluster-node-failure-recovery) | Cluster node failure recovery | 30 min |
| [6.7](#runbook-67--certificate-renewal) | Certificate renewal | 15 min |
| [6.8](#runbook-68--scale-frontend-manually) | Scale frontend manually | 2 min |

---

## Common SSH Aliases

```bash
# Add to ~/.bashrc on the hypervisor host for quick access
alias ssh-cp='ssh -i ~/PROJECT/phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.10'
alias ssh-w1='ssh -i ~/PROJECT/phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.20'
alias ssh-w2='ssh -i ~/PROJECT/phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.30'
alias ssh-nfs='ssh -i ~/PROJECT/phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.40'
alias ssh-lb='ssh -i ~/PROJECT/phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.50'
alias ssh-db='ssh -i ~/PROJECT/phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@192.168.1.60'
```

---

## Runbook 6.1 — Add a Worker Node

**When to use**: Cluster capacity is running low (CPU > 80% sustained, or HPA at max replicas).

### Prerequisites

- New VM provisioned via Terraform (add to `phase1-kvm-infrastructure/terraform/main.tf`) or manually via `virsh`
- Ubuntu 24.04 LTS, containerd installed, kubeadm/kubelet/kubectl at cluster version

### Step 1 — Prepare the new node

```bash
ssh ubuntu@<NEW_NODE_IP>

# Install container runtime dependencies (same as worker cloud-init)
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gpg containerd

# Configure containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# Disable swap (Kubernetes requirement)
sudo swapoff -a
sudo sed -i '/swap/d' /etc/fstab

# Load required kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Set sysctl params
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# Install kubeadm, kubelet, kubectl at the cluster version
KUBE_VERSION=$(ssh ubuntu@192.168.1.10 kubectl version --short 2>/dev/null | grep Server | awk '{print $3}' | tr -d 'v')
sudo apt-get install -y "kubeadm=${KUBE_VERSION}-*" "kubelet=${KUBE_VERSION}-*" "kubectl=${KUBE_VERSION}-*"
sudo apt-mark hold kubelet kubeadm kubectl
sudo systemctl enable kubelet
```

### Step 2 — Generate a join token on the control plane

```bash
ssh ubuntu@192.168.1.10

# Tokens expire after 24h — generate a fresh one
kubeadm token create --print-join-command
# Output example:
# kubeadm join 192.168.1.10:6443 --token <TOKEN> \
#   --discovery-token-ca-cert-hash sha256:<HASH>
```

### Step 3 — Join the new node

```bash
ssh ubuntu@<NEW_NODE_IP>

# Run the join command from Step 2 (as root)
sudo kubeadm join 192.168.1.10:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH>
```

### Step 4 — Label and verify

```bash
ssh ubuntu@192.168.1.10

# Wait for node to appear
kubectl get nodes --watch
# New node starts NotReady (Cilium is installing) → Ready within ~60s

# Label as worker
kubectl label node <NEW_NODE_NAME> node-role.kubernetes.io/worker=worker

# Verify
kubectl get nodes -o wide
# All nodes should show Ready
```

---

## Runbook 6.2 — Remove a Worker Node

**When to use**: Decommissioning a node, maintenance, hardware replacement.

> **Warning**: Do NOT drain the control plane node. Only drain workers.

### Step 1 — Cordon the node (stop new pods from scheduling)

```bash
ssh ubuntu@192.168.1.10

NODE_NAME=<NODE_TO_REMOVE>   # e.g. w-02

kubectl cordon ${NODE_NAME}
# Node is now SchedulingDisabled — existing pods continue running
```

### Step 2 — Drain (evict all pods gracefully)

```bash
kubectl drain ${NODE_NAME} \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=60 \
  --timeout=300s

# Watch pods move to the remaining nodes
kubectl get pods -n production -o wide --watch
# postgres-0 will reschedule on another node and reattach its NFS PVC
```

### Step 3 — Remove from the cluster

```bash
# Remove from Kubernetes
kubectl delete node ${NODE_NAME}

# On the node itself — reset kubeadm state
ssh ubuntu@<NODE_IP>
sudo kubeadm reset --force
sudo rm -rf /etc/cni/net.d /etc/kubernetes ~/.kube
```

### Step 4 — Verify cluster health

```bash
ssh ubuntu@192.168.1.10

kubectl get nodes
# NODE_NAME should be gone; remaining nodes Ready

kubectl get pods -n production -o wide
# All pods Running on remaining nodes

# If postgres-0 is Pending, it's waiting for the NFS PVC to re-bind
kubectl describe pod postgres-0 -n production
# Event should show "Successfully attached volume" within 60s
```

---

## Runbook 6.3 — Rolling Application Update

**When to use**: New version of frontend, backend, or database is ready to deploy.

### Step 1 — Build and transfer the new image

```bash
# On build host
cd phase3-application-deployment

# Example: update backend
docker build -t bmi-health/backend:1.1.0 ./backend

docker save bmi-health/backend:1.1.0 | gzip > bmi-backend-1.1.0.tar.gz

for NODE in 192.168.1.10 192.168.1.20 192.168.1.30; do
  scp -i phase1-kvm-infrastructure/.ssh/id_rsa \
    bmi-backend-1.1.0.tar.gz ubuntu@${NODE}:/tmp/
  ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@${NODE} \
    "gunzip -c /tmp/bmi-backend-1.1.0.tar.gz | sudo ctr -n k8s.io images import --label io.cri-containerd.image=managed - && rm /tmp/bmi-backend-1.1.0.tar.gz"
done
```

### Step 2 — Update the image in the manifest and apply

```bash
ssh ubuntu@192.168.1.10

# Edit the image tag in the manifest
sed -i 's|bmi-health/backend:1.0.0|bmi-health/backend:1.1.0|' \
  phase3-application-deployment/manifests/04-backend.yaml

kubectl apply -f phase3-application-deployment/manifests/04-backend.yaml
```

### Step 3 — Monitor the rollout

```bash
kubectl rollout status deployment/backend -n production --timeout=180s
# Waiting for rollout to finish: 1 old replicas are pending termination...
# deployment "backend" successfully rolled out

kubectl get pods -n production
# Both backend replicas should show the new image
kubectl describe pod -l app=backend -n production | grep Image:
```

### Step 4 — Rollback if needed

```bash
# Kubernetes keeps the previous ReplicaSet — rollback is instant
kubectl rollout undo deployment/backend -n production

kubectl rollout status deployment/backend -n production --timeout=120s
# Previous version is restored
```

---

## Runbook 6.4 — Database Restore from pg_dump Backup

**When to use**: Data corruption, accidental DELETE, or major application bug that corrupted records.

> **Warning**: `pg_restore --clean` drops all tables before restoring. Do this in a maintenance window.

### Step 1 — Identify the backup to restore

```bash
# List available backups
kubectl run restore-helper --rm -it --restart=Never \
  --image=busybox \
  --overrides='{
    "spec":{
      "volumes":[{"name":"b","persistentVolumeClaim":{"claimName":"pg-backup-storage"}}],
      "containers":[{"name":"r","image":"busybox","command":["ls","-lh","/backups"],
        "volumeMounts":[{"name":"b","mountPath":"/backups"}]}]
    }}' \
  -n production

# Note the timestamp directory you want to restore (e.g. 20260623_020001)
RESTORE_TIMESTAMP=20260623_020001
```

### Step 2 — Scale down backend (prevent new writes during restore)

```bash
ssh ubuntu@192.168.1.10

kubectl scale deployment/backend -n production --replicas=0
kubectl get pods -n production | grep backend
# No backend pods running
```

### Step 3 — Run pg_restore

```bash
kubectl run pg-restore --rm -it --restart=Never \
  --image=postgres:17-alpine \
  --env="PGPASSWORD=StrongP@ssw0rd!" \
  --overrides="{
    \"spec\":{
      \"volumes\":[{\"name\":\"b\",\"persistentVolumeClaim\":{\"claimName\":\"pg-backup-storage\"}}],
      \"containers\":[{
        \"name\":\"r\",
        \"image\":\"postgres:17-alpine\",
        \"command\":[\"sh\",\"-c\",
          \"pg_restore --host=postgres-service.production.svc.cluster.local --port=5432 --username=bmi_user --dbname=bmidb --clean --if-exists --verbose /backups/${RESTORE_TIMESTAMP}/bmidb.dump\"],
        \"env\":[{\"name\":\"PGPASSWORD\",\"value\":\"StrongP@ssw0rd!\"}],
        \"volumeMounts\":[{\"name\":\"b\",\"mountPath\":\"/backups\"}]
      }]
    }}" \
  -n production

# Watch output for:
# pg_restore: processing data for table "public.measurements"
# pg_restore: finished main parallel loop
```

### Step 4 — Verify data integrity and scale backend back up

```bash
# Quick record count check
kubectl exec postgres-0 -n production -- \
  psql -U bmi_user -d bmidb -c "SELECT COUNT(*) FROM measurements;"

# Scale backend back
kubectl scale deployment/backend -n production --replicas=2
kubectl rollout status deployment/backend -n production --timeout=120s

# End-to-end test
curl -s http://192.168.100.10/api/measurements | jq '.rows | length'
```

---

## Runbook 6.5 — Emergency Failover to db-01 VM

**When to use**: The Kubernetes PostgreSQL StatefulSet is unrecoverable (NFS failure, corrupted PVC, cluster outage) and the application must stay up using the standalone `db-01` VM (192.168.1.60).

### Step 1 — Verify db-01 is healthy

```bash
ssh ubuntu@192.168.1.60

sudo systemctl status postgresql
# Active: active (running)

psql -U bmi_user -d bmidb -c "SELECT COUNT(*) FROM measurements;"
# Should return last-known row count from the most recent pg_dump sync
```

### Step 2 — Restore the latest backup to db-01 (if not already current)

```bash
ssh ubuntu@192.168.1.60

# Mount the NFS backup volume
sudo mkdir -p /mnt/pg-backups
sudo mount 192.168.2.40:/nfs/kubernetes /mnt/pg-backups

# Find the latest backup directory (NFS provisioner uses dynamic sub-paths)
LATEST=$(ls -t /mnt/pg-backups/*/pg-backup-storage-*/bmidb.dump 2>/dev/null | head -1)

# Restore
PGPASSWORD=StrongP@ssw0rd! pg_restore \
  --host=localhost \
  --username=bmi_user \
  --dbname=bmidb \
  --clean \
  --if-exists \
  --verbose \
  ${LATEST}

sudo umount /mnt/pg-backups
```

### Step 3 — Update the backend Secret to point to db-01

```bash
ssh ubuntu@192.168.1.10

# Create updated secret pointing to db-01 instead of postgres-service
kubectl create secret generic bmi-secrets \
  --namespace production \
  --from-literal=db-user=bmi_user \
  --from-literal=db-password='StrongP@ssw0rd!' \
  --from-literal=database-url='postgresql://bmi_user:StrongP@ssw0rd!@192.168.1.60:5432/bmidb' \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Step 4 — Restart backend pods to pick up the new secret

```bash
kubectl rollout restart deployment/backend -n production
kubectl rollout status deployment/backend -n production --timeout=120s

# Verify backend connects to db-01
kubectl logs deployment/backend -n production | grep -i "database\|postgres\|connect"
```

### Step 5 — Allow db-01 connections from pod CIDR

```bash
ssh ubuntu@192.168.1.60

# Add pod network CIDR to pg_hba.conf (allow connections from K8s pods)
POD_CIDR="10.244.0.0/16"  # matches --pod-network-cidr from kubeadm init
echo "host  bmidb  bmi_user  ${POD_CIDR}  md5" | \
  sudo tee -a /etc/postgresql/*/main/pg_hba.conf

sudo systemctl reload postgresql
```

### Step 6 — Verify end-to-end

```bash
curl -s http://192.168.100.10/api/measurements | jq '.rows | length'
# Should return actual row count from db-01

# Post a test measurement
curl -s -X POST http://192.168.100.10/api/measurements \
  -H 'Content-Type: application/json' \
  -d '{"weightKg":75,"heightCm":180,"age":35,"sex":"male","activity":"heavy"}' \
  | jq .measurement.bmi
# Expected: ~23.1
```

### Reverting the failover (when Kubernetes DB is recovered)

```bash
# 1. Restore original DATABASE_URL secret
kubectl create secret generic bmi-secrets \
  --namespace production \
  --from-literal=db-user=bmi_user \
  --from-literal=db-password='StrongP@ssw0rd!' \
  --from-literal=database-url='postgresql://bmi_user:StrongP@ssw0rd!@postgres-service.production.svc.cluster.local:5432/bmidb' \
  --dry-run=client -o yaml | kubectl apply -f -

# 2. pg_dump from db-01 → restore to postgres-0 (sync data written during failover)
# 3. Restart backend
kubectl rollout restart deployment/backend -n production
```

---

## Runbook 6.6 — Cluster Node Failure Recovery

**When to use**: A worker node VM crashes (kernel panic, OOM, power loss).

### Step 1 — Identify the failed node

```bash
ssh ubuntu@192.168.1.10

kubectl get nodes
# Failed node shows NotReady

# Check how long it has been NotReady
kubectl describe node <FAILED_NODE> | grep -A5 "Conditions:"
```

### Step 2 — Wait for automatic pod rescheduling (5 minutes by default)

Kubernetes marks pods on a NotReady node as `Unknown` and reschedules them
after `pod-eviction-timeout` (default 5 minutes). No manual intervention
needed if the node recovers within this window.

```bash
# Watch pods migrate
kubectl get pods -n production -o wide --watch
# postgres-0, backend-*, frontend-* will appear on remaining nodes
```

### Step 3 — If the node does NOT recover — force delete stuck pods

```bash
# Force delete Unknown pods (only after confirming node is truly dead)
kubectl delete pod <STUCK_POD> -n production --force --grace-period=0

# Remove the dead node from the cluster
kubectl delete node <FAILED_NODE>
```

### Step 4 — Restore or replace the VM

```bash
# Option A: Restart the KVM VM on the hypervisor
virsh start <VM_NAME>

# Option B: Recreate via Terraform
cd phase1-kvm-infrastructure
terraform apply -target=libvirt_domain.vms["w-02"]

# Then rejoin using Runbook 6.1 Step 2-4
```

---

## Runbook 6.7 — Certificate Renewal

**When to use**: `kubectl get nodes` returns `certificate has expired or is not yet valid`.
kubeadm certificates expire after 1 year by default.

```bash
ssh ubuntu@192.168.1.10

# Check expiry dates
sudo kubeadm certs check-expiration

# Renew all control plane certificates
sudo kubeadm certs renew all

# Restart control plane components to pick up new certs
sudo crictl rm $(sudo crictl ps -q)   # forces static pod restart via kubelet

# Refresh admin kubeconfig
sudo cp /etc/kubernetes/admin.conf ~/.kube/config
sudo chown $(id -u):$(id -g) ~/.kube/config

# Verify
kubectl get nodes
sudo kubeadm certs check-expiration
# All certs should show 1 year from today
```

---

## Runbook 6.8 — Scale Frontend Manually

**When to use**: Load spike, HPA not responding fast enough, or testing.

```bash
ssh ubuntu@192.168.1.10

# Scale up manually
kubectl scale deployment/frontend -n production --replicas=5

# Watch pods spin up
kubectl get pods -n production -l app=frontend --watch

# Scale back — HPA will take over automatically once CPU drops
kubectl scale deployment/frontend -n production --replicas=2
```

> **Note**: If HPA is active (`kubectl get hpa -n production`), manual scaling
> will be overridden by HPA within 30 seconds. Temporarily pause HPA for manual control:
> ```bash
> kubectl patch hpa frontend-hpa -n production -p '{"spec":{"minReplicas":5,"maxReplicas":5}}'
> # Restore after:
> kubectl patch hpa frontend-hpa -n production -p '{"spec":{"minReplicas":2,"maxReplicas":5}}'
> ```

---

## Quick Reference — Health Checks

```bash
# ── Cluster ──────────────────────────────────────────────────────────────────
kubectl get nodes                          # All Ready?
kubectl get pods -n production             # All Running?
kubectl get pods -n monitoring             # Prometheus, Grafana, Loki, Promtail?
kubectl get pods -n kong                   # Kong proxy running?

# ── Storage ──────────────────────────────────────────────────────────────────
kubectl get pvc -n production              # postgres-data Bound?
kubectl get pvc -n monitoring              # prometheus, grafana, loki Bound?
kubectl get pvc pg-backup-storage -n production  # backup PVC Bound?

# ── Services ─────────────────────────────────────────────────────────────────
kubectl get svc -n production              # postgres headless, backend/frontend ClusterIP?
kubectl get svc -n kong                    # kong-proxy NodePort 30080?
kubectl get svc -n monitoring              # prometheus NodePort 30090, grafana NodePort 30030?

# ── End-to-end ───────────────────────────────────────────────────────────────
curl -s http://192.168.100.10/api/measurements | jq '.rows | length'
curl -s http://192.168.100.10/ | grep -c 'BMI\|Health'
```

---

**Project**: agk Technical Assessment — Production-Grade Kubernetes on KVM  
**Phase**: 6 — Operations Runbooks  
