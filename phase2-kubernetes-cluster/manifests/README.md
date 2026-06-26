# Phase 2 — Kubernetes Manifests

This directory contains Kubernetes manifests that enforce network isolation and availability guarantees at the cluster level. Apply them after the cluster is bootstrapped (Tasks 2.1–2.3) and before deploying application workloads (Phase 3).

## Prerequisites

- The `production` namespace must exist (created in Phase 2 Task 2.4)
- The CNI plugin must support NetworkPolicy enforcement (Cilium, Calico, or Weave Net)

## Files

### `01-network-policies.yaml`

Implements 3-tier isolation using Kubernetes NetworkPolicies:

| Policy | Selector | Effect |
|--------|----------|--------|
| `default-deny-all` | All pods | Blocks all ingress and egress — zero-trust baseline |
| `allow-dns-egress` | All pods | Allows DNS (UDP/TCP 53) to kube-dns |
| `allow-kong-to-backend` | `app: backend` | Allows Kong namespace to reach backend on port 3000 |
| `allow-backend-to-database` | `app: postgres` | Allows backend pods to reach PostgreSQL on port 5432 |
| `allow-kong-to-frontend` | `app: frontend` | Allows Kong namespace to reach frontend on port 80 |
| `allow-monitoring-to-backend` | `app: backend` | Allows monitoring namespace (Prometheus) to scrape port 3000 |
| `allow-pg-backup-to-database` | `app: postgres` | Allows pg-backup CronJob to reach PostgreSQL on port 5432 |

### `02-pod-disruption-budgets.yaml`

Ensures minimum availability during voluntary disruptions (node drains, rolling updates):

| PDB | Selector | Setting | Effect |
|-----|----------|---------|--------|
| `frontend-pdb` | `app: frontend` | `minAvailable: 1` | At least 1 of 2 frontend pods stays up during maintenance |
| `backend-pdb` | `app: backend` | `minAvailable: 1` | At least 1 of 2 backend pods stays up during maintenance |
| `postgres-pdb` | `app: postgres` | `maxUnavailable: 0` | Database pod is never evicted by voluntary disruption |

## Usage

```bash
# Apply all manifests
kubectl apply -f phase2-kubernetes-cluster/manifests/

# Verify NetworkPolicies
kubectl get networkpolicies -n production

# Verify PodDisruptionBudgets
kubectl get poddisruptionbudgets -n production
```

## Notes

- NetworkPolicies take effect immediately after the CNI plugin syncs (typically < 30 seconds)
- PDBs only protect against *voluntary* disruptions (kubectl drain, cordon). They do not protect against node failures or crashes
- The `default-deny-all` policy means any new pod deployed without a matching allow policy will have no network access — this is by design
