#!/bin/bash
set -euo pipefail

# Phase 2 — Kubernetes Cluster Setup
# Automates: kubeadm init, worker join, Cilium CNI, NFS storage,
#            namespaces, quotas, PDBs, Metrics Server.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

SSH_KEY="${PROJECT_ROOT}/phase1-kvm-infrastructure/.ssh/id_rsa"
CP_IP="192.168.1.10"
W1_IP="192.168.1.20"
W2_IP="192.168.1.30"
NFS_IP="192.168.1.40"
SSH_OPTS="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10"
SSH_CMD="ssh ${SSH_OPTS} -i ${SSH_KEY}"
SCP_CMD="scp ${SSH_OPTS} -i ${SSH_KEY}"

run_remote() {
  local ip="$1"; shift
  ${SSH_CMD} "ubuntu@${ip}" "sudo bash -c '$(printf '%q ' "$@")'"
}

run_remote_raw() {
  local ip="$1"; shift
  ${SSH_CMD} "ubuntu@${ip}" "$@"
}

# ──────────────────────────────────────────────
# Task 2.1 – Initialize the Control Plane
# ──────────────────────────────────────────────
init_control_plane() {
  log_info "=== Task 2.1: Initializing Control Plane ==="

  # Copy kubeadm config
  run_remote_raw "$CP_IP" "mkdir -p \$HOME/manifests"

  log_info "Running kubeadm init on cp-01..."
  KUBEADM_OUTPUT=$(${SSH_CMD} "ubuntu@${CP_IP}" sudo kubeadm init \
    --apiserver-advertise-address=192.168.1.10 \
    --pod-network-cidr=10.244.0.0/16 \
    --service-cidr=10.96.0.0/12 \
    --control-plane-endpoint=192.168.1.10:6443 \
    --token-ttl=24h \
    --upload-certs \
    --v=2 2>&1)

  echo "$KUBEADM_OUTPUT"

  # Generate a fresh join command (more reliable than parsing multi-line output)
  JOIN_CMD=$(${SSH_CMD} "ubuntu@${CP_IP}" sudo kubeadm token create --print-join-command 2>&1)
  if [[ -z "$JOIN_CMD" ]]; then
    log_error "Could not generate join command from cp-01"
    exit 1
  fi
  echo "$JOIN_CMD" > /tmp/kubeadm-join-cmd.txt 2>/dev/null || echo "$JOIN_CMD" > "${SCRIPT_DIR}/kubeadm-join-cmd.txt"
  log_info "Join command saved"

  # Configure kubectl
  log_info "Configuring kubectl..."
  run_remote_raw "$CP_IP" "mkdir -p \$HOME/.kube && sudo cp /etc/kubernetes/admin.conf \$HOME/.kube/config && sudo chown \$(id -u):\$(id -g) \$HOME/.kube/config"

  # Verify
  run_remote_raw "$CP_IP" "kubectl cluster-info"
}

# ──────────────────────────────────────────────
# Task 2.1 – Install Cilium CNI
# ──────────────────────────────────────────────
install_cilium() {
  log_info "Installing Cilium CLI..."
  run_remote_raw "$CP_IP" "
    CILIUM_CLI_VERSION=\$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
    curl -L --remote-name-all \"https://github.com/cilium/cilium-cli/releases/download/\${CILIUM_CLI_VERSION}/cilium-linux-amd64.tar.gz\"
    sudo tar -C /usr/local/bin -xzf cilium-linux-amd64.tar.gz
    rm cilium-linux-amd64.tar.gz
  "

  log_info "Installing Cilium CNI..."
  run_remote_raw "$CP_IP" "
    cilium install --set ipam.mode=kubernetes --set kubeProxyReplacement=true --set k8sServiceHost=192.168.1.10 --set k8sServicePort=6443
  "

  log_info "Waiting for Cilium to be ready (2-3 minutes)..."
  run_remote_raw "$CP_IP" "cilium status --wait" || true

  # Remove kube-proxy
  log_info "Removing kube-proxy..."
  run_remote_raw "$CP_IP" "kubectl delete -n kube-system daemonset kube-proxy --ignore-not-found"
  run_remote_raw "$CP_IP" "kubectl delete -n kube-system configmap kube-proxy --ignore-not-found"

  log_info "Verifying Cilium..."
  run_remote_raw "$CP_IP" "cilium status"
}

# ──────────────────────────────────────────────
# Task 2.1 Verify – Pod connectivity test
# ──────────────────────────────────────────────
verify_cni() {
  log_info "Running CNI pod connectivity test..."
  run_remote_raw "$CP_IP" "
    kubectl create namespace test-cni --dry-run=client -o yaml | kubectl apply -f -
    kubectl run p1 --image=busybox:1.37 -n test-cni -- sleep 30 2>/dev/null || true
    kubectl run p2 --image=busybox:1.37 -n test-cni -- sleep 30 2>/dev/null || true
    kubectl wait --for=condition=Ready pod/p1 pod/p2 -n test-cni --timeout=60s
    P1_IP=\$(kubectl get pod p1 -n test-cni -o jsonpath='{.status.podIP}')
    kubectl exec p2 -n test-cni -- ping -c 3 \$P1_IP
    kubectl delete namespace test-cni --ignore-not-found
  "
}

# ──────────────────────────────────────────────
# Task 2.2 – Join Worker Nodes
# ──────────────────────────────────────────────
join_workers() {
  log_info "=== Task 2.2: Joining Worker Nodes ==="

  log_info "Generating fresh join token from cp-01..."
  local join_cmd
  join_cmd=$(${SSH_CMD} "ubuntu@${CP_IP}" sudo kubeadm token create --print-join-command 2>&1)
  if [[ -z "$join_cmd" ]]; then
    log_error "Failed to generate join command"
    exit 1
  fi
  echo "$join_cmd" > /tmp/kubeadm-join-cmd.txt 2>/dev/null || echo "$join_cmd" > "${SCRIPT_DIR}/kubeadm-join-cmd.txt"
  log_info "Join command: $join_cmd"

  log_info "Joining w-01..."
  ${SSH_CMD} "ubuntu@${W1_IP}" "sudo $join_cmd --v=2"

  log_info "Joining w-02..."
  ${SSH_CMD} "ubuntu@${W2_IP}" "sudo $join_cmd --v=2"

  log_info "Applying node labels..."
  run_remote_raw "$CP_IP" "
    kubectl label node w-01 node-role.kubernetes.io/worker=worker --overwrite
    kubectl label node w-02 node-role.kubernetes.io/worker=worker --overwrite
    kubectl label node w-01 workload=application --overwrite
    kubectl label node w-02 workload=application --overwrite
  "

  log_info "Verifying nodes..."
  run_remote_raw "$CP_IP" "kubectl get nodes -o wide"
}

# ──────────────────────────────────────────────
# Task 2.3 – NFS Persistent Storage
# ──────────────────────────────────────────────
setup_nfs_server() {
  log_info "Configuring NFS server on nfs-01..."
  ${SSH_CMD} "ubuntu@${NFS_IP}" "
    sudo apt-get install -y nfs-kernel-server -qq 2>/dev/null
    sudo mkdir -p /nfs/kubernetes
    sudo chown nobody:nogroup /nfs/kubernetes
    sudo chmod 755 /nfs/kubernetes
    echo '/nfs/kubernetes 192.168.2.0/24(rw,sync,no_subtree_check,no_root_squash,insecure)' | sudo tee /etc/exports
    sudo systemctl enable nfs-server
    sudo systemctl restart nfs-server
  " 2>&1
  ${SSH_CMD} "ubuntu@${NFS_IP}" "sudo systemctl is-active nfs-server && sudo exportfs -v"
}

setup_nfs() {
  log_info "=== Task 2.3: NFS Persistent Storage ==="

  setup_nfs_server

  log_info "Verifying NFS server on nfs-01..."
  run_remote_raw "$NFS_IP" "sudo systemctl is-active nfs-server && sudo exportfs -v && df -h /nfs/kubernetes"

  log_info "Installing nfs-common on all Kubernetes nodes..."
  for ip in "$CP_IP" "$W1_IP" "$W2_IP"; do
    run_remote_raw "$ip" "sudo apt-get install -y nfs-common"
  done

  log_info "Testing NFS mount from workers..."
  for ip in "$W1_IP" "$W2_IP"; do
    run_remote_raw "$ip" "
      sudo mkdir -p /mnt/nfs-test
      sudo mount -t nfs 192.168.2.40:/nfs/kubernetes /mnt/nfs-test
      df -h /mnt/nfs-test
      sudo umount /mnt/nfs-test
    "
  done

  log_info "Deploying NFS Subdir External Provisioner..."

  # RBAC
  run_remote_raw "$CP_IP" "
mkdir -p \$HOME/manifests/storage
cat > \$HOME/manifests/storage/nfs-rbac.yaml << 'EOF'
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
  - apiGroups: [\"\"]
    resources: [\"persistentvolumes\"]
    verbs: [\"get\",\"list\",\"watch\",\"create\",\"delete\"]
  - apiGroups: [\"\"]
    resources: [\"persistentvolumeclaims\"]
    verbs: [\"get\",\"list\",\"watch\",\"update\"]
  - apiGroups: [\"storage.k8s.io\"]
    resources: [\"storageclasses\"]
    verbs: [\"get\",\"list\",\"watch\"]
  - apiGroups: [\"\"]
    resources: [\"events\"]
    verbs: [\"create\",\"update\",\"patch\"]
  - apiGroups: [\"\"]
    resources: [\"endpoints\"]
    verbs: [\"get\",\"list\",\"watch\",\"create\",\"update\",\"patch\"]
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
kubectl apply -f \$HOME/manifests/storage/nfs-rbac.yaml
"

  # Provisioner Deployment
  run_remote_raw "$CP_IP" "
cat > \$HOME/manifests/storage/nfs-provisioner.yaml << 'EOF'
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
              value: \"192.168.2.40\"
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
kubectl apply -f \$HOME/manifests/storage/nfs-provisioner.yaml
kubectl rollout status deployment/nfs-provisioner -n kube-system --timeout=120s
"

  # StorageClass
  run_remote_raw "$CP_IP" "
cat > \$HOME/manifests/storage/nfs-storageclass.yaml << 'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nfs-client
  annotations:
    storageclass.kubernetes.io/is-default-class: \"true\"
provisioner: nfs.io/nfs-client
parameters:
  archiveOnDelete: \"false\"
reclaimPolicy: Delete
allowVolumeExpansion: true
EOF
kubectl apply -f \$HOME/manifests/storage/nfs-storageclass.yaml
kubectl get storageclass
"

  log_info "Verifying dynamic PVC provisioning..."
  run_remote_raw "$CP_IP" "
cat > \$HOME/manifests/storage/nfs-test-pvc.yaml << 'EOF'
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
      command: [\"sh\",\"-c\",\"echo NFS OK > /data/probe.txt; sleep 10\"]
      volumeMounts:
        - name: vol
          mountPath: /data
  volumes:
    - name: vol
      persistentVolumeClaim:
        claimName: nfs-test-pvc
  restartPolicy: Never
EOF
kubectl apply -f \$HOME/manifests/storage/nfs-test-pvc.yaml
kubectl wait --for=condition=Ready pod/nfs-test-pod --timeout=120s || true
kubectl get pvc nfs-test-pvc
kubectl exec nfs-test-pod -- cat /data/probe.txt || echo 'DATA_CHECK_FAILED'
kubectl delete -f \$HOME/manifests/storage/nfs-test-pvc.yaml --ignore-not-found
"
}

# ──────────────────────────────────────────────
# Task 2.4 – Cluster Networking & Security
# ──────────────────────────────────────────────
setup_security() {
  log_info "=== Task 2.4: Cluster Networking & Security ==="

  log_info "Creating project namespaces..."
  run_remote_raw "$CP_IP" "
    kubectl create namespace production --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
    kubectl create namespace kong --dry-run=client -o yaml | kubectl apply -f -
    kubectl label namespace production  kubernetes.io/metadata.name=production --overwrite
    kubectl label namespace monitoring  kubernetes.io/metadata.name=monitoring --overwrite
    kubectl label namespace kong        kubernetes.io/metadata.name=kong --overwrite
  "

  log_info "Applying ResourceQuotas and LimitRanges..."
  run_remote_raw "$CP_IP" "
mkdir -p \$HOME/manifests/governance

cat > \$HOME/manifests/governance/resource-quotas.yaml << 'EOF'
apiVersion: v1
kind: ResourceQuota
metadata:
  name: production-quota
  namespace: production
spec:
  hard:
    requests.cpu: \"2\"
    requests.memory: 2Gi
    limits.cpu: \"4\"
    limits.memory: 4Gi
    pods: \"15\"
    persistentvolumeclaims: \"5\"
---
apiVersion: v1
kind: ResourceQuota
metadata:
  name: monitoring-quota
  namespace: monitoring
spec:
  hard:
    requests.cpu: \"1\"
    requests.memory: 1Gi
    limits.cpu: \"4\"
    limits.memory: 4Gi
    pods: \"15\"
    persistentvolumeclaims: \"5\"
EOF
kubectl apply -f \$HOME/manifests/governance/resource-quotas.yaml

cat > \$HOME/manifests/governance/limit-ranges.yaml << 'EOF'
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
        cpu: \"2\"
        memory: 2Gi
      min:
        cpu: 50m
        memory: 64Mi
---
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
        cpu: \"2\"
        memory: 2Gi
      min:
        cpu: 50m
        memory: 64Mi
EOF
kubectl apply -f \$HOME/manifests/governance/limit-ranges.yaml
"

  log_info "Applying PodDisruptionBudgets..."
  run_remote_raw "$CP_IP" "
cat > \$HOME/manifests/governance/pod-disruption-budgets.yaml << 'EOF'
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
kubectl apply -f \$HOME/manifests/governance/pod-disruption-budgets.yaml
"
}

# ──────────────────────────────────────────────
# Task 2.5 – Metrics Server
# ──────────────────────────────────────────────
install_metrics_server() {
  log_info "=== Task 2.5: Metrics Server ==="

  run_remote_raw "$CP_IP" "
    curl -LO https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
    sed -i '/--metric-resolution/a\\        - --kubelet-insecure-tls' components.yaml
    kubectl apply -f components.yaml
    kubectl rollout status deployment/metrics-server -n kube-system --timeout=120s
  "

  sleep 10
  log_info "Verifying metrics..."
  run_remote_raw "$CP_IP" "kubectl top nodes || log_info 'Metrics may take another minute to appear'"
}

# ──────────────────────────────────────────────
# Verification
# ──────────────────────────────────────────────
verify_cluster() {
  log_info "=== Full Cluster Verification ==="

  run_remote_raw "$CP_IP" "
    echo '--- Nodes ---'
    kubectl get nodes -o wide

    echo '--- System Pods ---'
    kubectl get pods -n kube-system

    echo '--- StorageClass ---'
    kubectl get storageclass

    echo '--- NFS Provisioner ---'
    kubectl get deployment nfs-provisioner -n kube-system

    echo '--- Cilium Status ---'
    cilium status 2>/dev/null || true

    echo '--- Namespaces ---'
    kubectl get namespaces production monitoring kong --show-labels

    echo '--- ResourceQuotas ---'
    kubectl describe resourcequota -n production
    kubectl describe resourcequota -n monitoring

    echo '--- LimitRanges ---'
    kubectl get limitrange --all-namespaces

    echo '--- PDBs ---'
    kubectl get poddisruptionbudgets -n production

    echo '--- Metrics Server ---'
    kubectl get deployment metrics-server -n kube-system
  "
}

# ──────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────
main() {
  log_info "Starting Phase 2: Kubernetes Cluster Setup"

  if [[ ! -f "$SSH_KEY" ]]; then
    log_error "SSH key not found at $SSH_KEY — deploy Phase 1 first"
    exit 1
  fi

  init_control_plane
  install_cilium
  verify_cni
  join_workers
  setup_nfs_server
  setup_nfs
  setup_security
  install_metrics_server
  verify_cluster

  log_info "Phase 2 complete! Proceed to Phase 3 — Application Deployment"
  log_info "Manifests location: ~/manifests/ on cp-01"
}

main "$@"
