# Phase 5: Security Hardening

 — agk Technical Assessment
**Scope**: PSA labels, dedicated ServiceAccounts, RBAC, NetworkPolicies, securityContext patches
**Prerequisites**: Phase 3 complete — all application pods Running

---

## Implementation Files

This directory contains two implementation artifacts that support the hardening steps below:

### `manifests/01-pod-security-admission.yaml`

A Namespace manifest for `production` that enforces the **restricted** Pod Security Admission profile across all three modes (enforce, warn, audit). This blocks privileged containers, host namespace sharing, privilege escalation, and requires non-root users with seccomp profiles.

**Apply with:**
```bash
kubectl apply -f phase5-security-hardening/manifests/01-pod-security-admission.yaml
```

### `scripts/harden-host.sh`

A bash hardening script to run as root on each KVM host node. It:
1. Hardens SSH configuration (PasswordAuthentication no, PermitRootLogin no, MaxAuthTries 3)
2. Applies UFW firewall rules (default deny incoming, allow only essential ports from internal networks)
3. Sets kernel sysctl hardening parameters (disable redirects, restrict dmesg)
4. Disables unnecessary services (avahi-daemon, cups, bluetooth)

**Run with:**
```bash
sudo bash phase5-security-hardening/scripts/harden-host.sh
```

---

## Step 1 — Apply Pod Security Admission Labels

PSA is set to `warn` + `audit` only. `enforce` is commented out because the frontend nginx and postgres images need root-level access during startup. Switch to `enforce=restricted` after rebuilding images with non-root entrypoints.

**What's needed to enable `enforce=restricted`:**

| Image | Current blocker | Required change |
|-------|----------------|----------------|
| `frontend` (nginx) | Nginx entrypoint runs as root; binds to port 80 | Rebuild with a non-root nginx config (use `nginx:1.27-alpine-slim` with `USER nginx` before `CMD`) |
| `postgres` (StatefulSet) | Postgres initdb needs root capabilities on NFS | Switch to a dedicated NFS-compatible postgres image or patch the container to run with `fsGroup` and adjust directory ownership |

**Target milestone:** After Phase 7 CI/CD integration — rebuild both images using the pipeline (see [Runbook 6.3 — Rolling Application Update](../../phase6-runbooks/README.md#runbook-63--rolling-application-update)), push updated manifests, then switch `enforce` from commented to active. This is a post-assessment production hardening task.

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    name: production
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/warn-version: latest
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/audit-version: latest
    #pod-security.kubernetes.io/enforce: restricted
    #pod-security.kubernetes.io/enforce-version: latest
---
apiVersion: v1
kind: Namespace
metadata:
  name: monitoring
  labels:
    name: monitoring
    pod-security.kubernetes.io/warn: baseline
    pod-security.kubernetes.io/warn-version: latest
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/audit-version: latest
    #pod-security.kubernetes.io/enforce: baseline
    #pod-security.kubernetes.io/enforce-version: latest
EOF
```

## Step 2 — Create Dedicated ServiceAccounts

Each tier gets its own SA with `automountServiceAccountToken: false` (no pod needs runtime API access).

```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: frontend-sa
  namespace: production
automountServiceAccountToken: false
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: backend-sa
  namespace: production
automountServiceAccountToken: false
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: postgres-sa
  namespace: production
automountServiceAccountToken: false
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: pg-backup-sa
  namespace: production
automountServiceAccountToken: false
EOF
```

## Step 3 — Apply RBAC (Least-Privilege)

backend-sa can GET bmi-secrets and bmi-config only (cannot list secrets). pg-backup-sa can GET bmi-secrets only.

```bash
kubectl apply -f - <<'EOF'
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: backend-secret-reader
  namespace: production
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["bmi-secrets"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["bmi-config"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: backend-secret-reader
  namespace: production
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: backend-secret-reader
subjects:
  - kind: ServiceAccount
    name: backend-sa
    namespace: production
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pg-backup-secret-reader
  namespace: production
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["bmi-secrets"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pg-backup-secret-reader
  namespace: production
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pg-backup-secret-reader
subjects:
  - kind: ServiceAccount
    name: pg-backup-sa
    namespace: production
EOF
```

## Step 4 — Apply NetworkPolicies (Zero-Trust)

Default-deny all ingress + egress in production. Then allow only:
1. DNS egress (UDP/TCP 53) for all pods
2. Frontend ingress from Kong namespace (port 80)
3. Backend ingress from Kong (port 3000) + Prometheus (port 3000); egress to PostgreSQL (5432)
4. PostgreSQL ingress from backend (5432) + pg-backup CronJob (5432)
5. Kong-to-frontend ingress allow

```bash
kubectl apply -f - <<'EOF'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Ingress
    - Egress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: production
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: frontend-policy
  namespace: production
spec:
  podSelector:
    matchLabels:
      tier: frontend
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kong
      ports:
        - port: 80
  egress:
    - ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: backend-policy
  namespace: production
spec:
  podSelector:
    matchLabels:
      tier: backend
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kong
      ports:
        - port: 3000
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
      ports:
        - port: 3000
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: postgres
      ports:
        - port: 5432
    - ports:
        - port: 53
          protocol: UDP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: postgres-policy
  namespace: production
spec:
  podSelector:
    matchLabels:
      app: postgres
  policyTypes:
    - Ingress
    - Egress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              tier: backend
      ports:
        - port: 5432
    - from:
        - podSelector:
            matchLabels:
              app: pg-backup
      ports:
        - port: 5432
  egress:
    - ports:
        - port: 53
          protocol: UDP
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-kong-to-production
  namespace: production
spec:
  podSelector:
    matchLabels:
      tier: frontend
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kong
EOF
```

## Step 5 — Patch Security Contexts

The backend gets full restricted securityContext. Frontend and postgres get seccomp only (no `runAsNonRoot` — nginx entrypoint runs as root, postgres initdb needs capabilities on NFS).

```bash
# Backend — full restricted securityContext
kubectl patch deployment backend -n production --type json -p='[
  {"op":"add","path":"/spec/template/spec/securityContext","value":{
    "runAsNonRoot": true,
    "runAsUser": 1000,
    "runAsGroup": 1000,
    "fsGroup": 1000,
    "seccompProfile": {"type":"RuntimeDefault"}
  }},
  {"op":"add","path":"/spec/template/spec/containers/0/securityContext","value":{
    "allowPrivilegeEscalation": false,
    "capabilities":{"drop":["ALL"]}
  }}
]'

# Frontend — seccomp only (nginx needs root for startup)
kubectl patch deployment frontend -n production --type json -p='[
  {"op":"add","path":"/spec/template/spec/securityContext","value":{
    "seccompProfile": {"type":"RuntimeDefault"}
  }}
]'

# Postgres — seccomp only (initdb needs capabilities on NFS)
kubectl patch statefulset postgres -n production --type json -p='[
  {"op":"add","path":"/spec/template/spec/securityContext","value":{
    "seccompProfile": {"type":"RuntimeDefault"}
  }}
]'

# Fix postgres PVC ownership (NFS requires explicit chown)
kubectl exec postgres-0 -n production -- sudo chown -R 999:999 /var/lib/postgresql/data/pgdata
```

> **Note**: If postgres-0 is not running yet after the patch, you may need to manually chown the NFS directory from the NFS server:
> ```bash
> ssh ubuntu@192.168.1.40
> sudo chown -R 999:999 /nfs/kubernetes/*/postgres-data-postgres-0-*
> ```

## Step 6 — Verify

```bash
# All pods should be Running (may need rollout restart after patches)
kubectl rollout restart deployment backend -n production
kubectl rollout restart deployment frontend -n production
kubectl delete pod postgres-0 -n production

kubectl rollout status deployment backend -n production --timeout=120s
kubectl rollout status deployment frontend -n production --timeout=120s
kubectl wait --for=condition=Ready pod/postgres-0 -n production --timeout=120s

# Confirm securityContext on backend
kubectl get pod -l app=backend -n production -o json | jq '.items[0].spec.securityContext'

# End-to-end
curl -s http://192.168.100.10/api/measurements | jq '.rows | length'
curl -s http://192.168.100.10/ | grep -c 'BMI\|Health'
```

---

**Project**: agk Technical Assessment — Production-Grade Kubernetes on KVM
**Phase**: 5 — Security Hardening
