# Phase 3: Application Deployment

 — agk Technical Assessment
**Application**: BMI & Health Tracker (3-tier: React · Node.js · PostgreSQL)
**Prerequisites**: Phase 2 cluster running — all nodes Ready, NFS StorageClass available, kubectl on cp-01

---

## Step 1 — Build Docker Images

Run on a build host with Docker (EC2 jump host or hypervisor):

```bash
cd phase3-application-deployment

sudo usermod -aG docker $USER
newgrp docker
sudo systemctl restart docker


docker build -t bmi-health/frontend:1.0.0 ./frontend
docker build -t bmi-health/backend:1.0.0  ./backend
docker build -t bmi-health/database:1.0.0 ./database

docker images | grep bmi-health
```

## Step 2 — Transfer Images to All Nodes

```bash
docker save bmi-health/frontend:1.0.0 | gzip > /tmp/bmi-frontend.tar.gz
docker save bmi-health/backend:1.0.0  | gzip > /tmp/bmi-backend.tar.gz
docker save bmi-health/database:1.0.0 | gzip > /tmp/bmi-database.tar.gz

for NODE in 192.168.1.10 192.168.1.20 192.168.1.30; do
  scp -i phase1-kvm-infrastructure/.ssh/id_rsa /tmp/bmi-*.tar.gz ubuntu@${NODE}:/tmp/
  ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@${NODE} "
    for f in /tmp/bmi-*.tar.gz; do
      gunzip -c \"\$f\" | sudo ctr -n k8s.io images import -
    done
    rm /tmp/bmi-*.tar.gz
  "
done
# NOTE: --label io.cri-containerd.image=managed is NOT a valid flag on the
# ctr build shipped with containerd.io 1.7.x ("flag provided but not
# defined: -label") — omit it, as above. It is unnecessary; ctr images
# import already registers the image correctly for containerd's CRI plugin.

for NODE in 192.168.1.10 192.168.1.20 192.168.1.30; do
  echo "=== $NODE ==="
  ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@${NODE} \
    "sudo ctr -n k8s.io images ls | grep bmi-health"
done
```

## Step 3 — Apply Manifests

Run all commands below on cp-01 (192.168.1.10).

```bash
# Directory containing all YAML manifests
cd phase3-application-deployment/manifests

# Step 3a — Namespace, ConfigMap, Secret
kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-configmap.yaml
kubectl apply -f 02-secret.yaml

# Step 3b — Create ServiceAccounts
for sa in postgres-sa backend-sa frontend-sa; do
  kubectl create sa "${sa}" -n production --dry-run=client -o yaml | kubectl apply -f -
done

# Step 3c — Application workloads (order matters: database first)
kubectl apply -f 03-database.yaml
kubectl apply -f 04-backend.yaml
kubectl apply -f 05-frontend.yaml

# Step 3d — Wait for all pods
kubectl rollout status statefulset/postgres -n production --timeout=120s
kubectl rollout status deployment/backend   -n production --timeout=120s
kubectl rollout status deployment/frontend  -n production --timeout=120s

kubectl get pods -n production -o wide
kubectl get pvc -n production
kubectl get svc -n production
```

## Step 4 — Test Backend Directly

```bash
kubectl port-forward svc/backend-service 3000:3000 -n production &
curl http://localhost:3000/health
curl -s http://localhost:3000/api/measurements | jq '.rows | length'
kill %1
```

## Step 5 — Install Kong API Gateway

```bash
# Install Helm
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Install Kong
helm repo add kong https://charts.konghq.com
helm repo update

helm upgrade --install kong kong/ingress -n kong --create-namespace \
  --set ingressController.env.publish_service=production/backend-service \
  --set gateway.env.database=off \
  --set gateway.proxy.type=NodePort \
  --set gateway.proxy.nodePorts.http=30080 \
  --set gateway.proxy.nodePorts.https=30443 \
  --wait --timeout 10m

kubectl rollout status deployment/kong-gateway -n kong --timeout=300s
kubectl get pods -n kong
```

> **Known chart issue**: `gateway.proxy.nodePorts.http/https` is accepted by
> `helm upgrade --install` without error but does **not** get applied to the
> resulting `kong-gateway-proxy` Service on chart version installed from the
> `kong/ingress` repo as of this writing — `kubectl get svc -n kong` will show
> a randomly-assigned NodePort instead of 30080/30443. Patch it explicitly
> after install:
> ```bash
> kubectl patch svc kong-gateway-proxy -n kong --type=json -p '[
>   {"op":"replace","path":"/spec/ports/0/nodePort","value":30080},
>   {"op":"replace","path":"/spec/ports/1/nodePort","value":30443}
> ]'
> kubectl get svc kong-gateway-proxy -n kong
> # Expected: 80:30080/TCP,443:30443/TCP
> ```
> This is required — lb-01's HAProxy config (Phase 1 cloud-init) forwards to
> `w-01/w-02:30080` unconditionally.

### Apply Kong routing rules

```bash
# NOTE: manifests/06-kong.yaml documents the alternative *manual* (no-Helm)
# Kong install (kubectl apply of the all-in-one-dbless.yaml, selector
# app=ingress-kong). Do NOT apply it after the Helm install above — its
# `kong-proxy` Service selector does not match the Helm-installed gateway
# pods and creates a second, non-functional Service. Skip straight to the
# routes file, which is install-method-agnostic (it only depends on an
# IngressClass named "kong", which the Helm chart's controller registers).
kubectl apply -f manifests/07-kong-routes.yaml

kubectl get ingressclass
kubectl get ingress -n production

# Label kong namespace for NetworkPolicy selectors
kubectl label namespace kong kubernetes.io/metadata.name=kong --overwrite
```

## Step 6 — Configure HAProxy on lb-01

> Phase 1 cloud-init (`phase1-kvm-infrastructure/cloud-init/load-balancer.yaml`)
> now installs and starts HAProxy with this exact config automatically —
> verify with `ssh ubuntu@192.168.1.50 "systemctl is-active haproxy"` first.
> This step is an idempotent fallback if that failed or you need to change
> the backend list; re-running it is safe.

SSH into lb-01 (192.168.1.50) and run:

```bash
sudo apt-get update
sudo apt-get install -y haproxy -qq

sudo tee /etc/haproxy/haproxy.cfg > /dev/null <<'EOF'
global
        log /dev/log    local0
        log /dev/log    local1 notice
        stats socket /run/haproxy/admin.sock mode 660 level admin
        stats timeout 30s
        user haproxy
        group haproxy

defaults
        log     global
        mode    tcp
        option  tcplog
        option  dontlognull
        timeout connect 5000
        timeout client  50000
        timeout server  50000

frontend k8s_frontend
        bind *:80
        mode tcp
        default_backend k8s_workers

backend k8s_workers
        mode tcp
        balance roundrobin
        server w-01 192.168.1.20:30080 check
        server w-02 192.168.1.30:30080 check
EOF

echo "" | sudo tee -a /etc/haproxy/haproxy.cfg > /dev/null
haproxy -c -f /etc/haproxy/haproxy.cfg -V
sudo systemctl restart haproxy
sudo systemctl enable haproxy
sudo ss -tlnp | grep haproxy
```

> **HAProxy gotchas**: Do NOT use `chroot` or `daemon` — they conflict with systemd's `-Ws` master-worker mode. Always add a trailing newline. Use `mode tcp` (L4) for NodePort forwarding.

## Step 7 — End-to-End Verification

From any host that can reach 192.168.100.10:

```bash
curl -s http://192.168.100.10/ | grep -i 'BMI\|health'
curl -s http://192.168.100.10/api/measurements | jq '.rows | length'

curl -s -X POST http://192.168.100.10/api/measurements \
  -H 'Content-Type: application/json' \
  -d '{"weightKg":70,"heightCm":175,"age":30,"sex":"male","activity":"moderate"}' \
  | jq .
```

---

## Troubleshooting

| Problem | Check |
|---------|-------|
| postgres-0 stuck Pending | `kubectl describe pvc postgres-data-postgres-0 -n production` |
| Backend CrashLoopBackOff | `kubectl logs deployment/backend -n production` — usually wrong DATABASE_URL |
| Kong not routing | `kubectl logs -n kong deployment/kong-gateway --tail=30` |
| HPA shows unknown CPU | Metrics Server may not be running — `kubectl get deployment metrics-server -n kube-system` |

---

**Project**: agk Technical Assessment — Production-Grade Kubernetes on KVM
**Phase**: 3 — Application Deployment
