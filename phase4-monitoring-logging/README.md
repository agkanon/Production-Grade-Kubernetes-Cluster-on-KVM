# Phase 4: Monitoring, Logging & Backup

 — agk Technical Assessment
**Components**: Prometheus + Node Exporter, Grafana, Loki + Promtail, pg_dump CronJob
**Prerequisites**: Phase 3 complete — application pods Running, NFS StorageClass available

---

## Step 1 — Pull and Import Images

Run on the build host (same as Phase 3):

```bash
docker pull prom/prometheus:v2.53.1
docker pull prom/node-exporter:v1.8.2
docker pull grafana/grafana:11.2.0
docker pull grafana/loki:3.1.0
docker pull grafana/promtail:3.1.0
docker pull postgres:17-alpine

for img in prom/prometheus:v2.53.1 prom/node-exporter:v1.8.2 grafana/grafana:11.2.0 \
           grafana/loki:3.1.0 grafana/promtail:3.1.0 postgres:17-alpine; do
  name=$(echo "$img" | tr '/' '_' | tr ':' '-')
  docker save "$img" | gzip > "/tmp/${name}.tar.gz"
done

# NOTE: no --label flag on the import below — it is not a valid flag on the
# ctr shipped with containerd.io 1.7.x ("flag provided but not defined:
# -label") and causes the import to fail outright.
for NODE in 192.168.1.10 192.168.1.20 192.168.1.30; do
  scp -i phase1-kvm-infrastructure/.ssh/id_rsa /tmp/*.tar.gz ubuntu@${NODE}:/tmp/
  ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@${NODE} "
    for f in /tmp/*.tar.gz; do
      gunzip -c \"\$f\" | sudo ctr -n k8s.io images import -
    done
    rm /tmp/*.tar.gz
  "
done

for NODE in 192.168.1.10 192.168.1.20 192.168.1.30; do
  echo "=== $NODE ==="
  ssh -i phase1-kvm-infrastructure/.ssh/id_rsa ubuntu@${NODE} \
    "sudo ctr -n k8s.io images ls | grep -E 'prometheus|grafana|loki|postgres'"
done
```

## Step 2 — Apply Monitoring Manifests

Run on cp-01 (192.168.1.10):

```bash
cd phase4-monitoring-logging/manifests

kubectl apply -f 00-namespace.yaml
kubectl apply -f 01-rbac.yaml
kubectl apply -f 02-prometheus.yaml
kubectl apply -f 03-node-exporter.yaml
kubectl apply -f 04-grafana.yaml
kubectl apply -f 05-loki.yaml
kubectl apply -f 06-promtail.yaml

kubectl rollout status deployment/prometheus -n monitoring --timeout=120s
kubectl rollout status deployment/grafana    -n monitoring --timeout=120s
kubectl rollout status deployment/loki       -n monitoring --timeout=120s
kubectl rollout status daemonset/node-exporter -n monitoring --timeout=60s
kubectl rollout status daemonset/promtail    -n monitoring --timeout=60s

kubectl get pods -n monitoring -o wide
```

## Step 3 — Deploy pg_dump Backup CronJob

The CronJob runs daily at 02:00 UTC and writes to a 20Gi NFS PVC.

```bash
cd phase4-monitoring-logging/manifests

kubectl create sa pg-backup-sa -n production --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f 07-pg-dump-cronjob.yaml

kubectl get pvc -n production | grep pg-backup
```

### Manual backup test

```bash
kubectl create job --from=cronjob/pg-daily-backup manual-test -n production
kubectl wait --for=condition=complete job/manual-test -n production --timeout=60s
kubectl logs job/manual-test -n production

# to show db backup via temporary pod
kubectl run pvc-check --rm -it --image=busybox -n production \
  --overrides='{"spec":{"containers":[{"name":"pvc-check","image":"busybox","command":["sh"],"stdin":true,"tty":true,"volumeMounts":[{"name":"backup","mountPath":"/backups"}]}],"volumes":[{"name":"backup","persistentVolumeClaim":{"claimName":"pg-backup-storage"}}]}}' \
  -- sh

```

## Step 4 — Verify

```bash
# Prometheus targets (expect 11 UP)
kubectl port-forward svc/prometheus 9090:9090 -n monitoring &
curl -s http://localhost:9090/api/v1/targets | jq '.data.activeTargets | length'
kill %1

# Grafana accessible
curl -s -o /dev/null -w "%{http_code}" http://192.168.100.10:30030/login

# All PVCs Bound
kubectl get pvc -n monitoring
```

---

**Dashboard access**:

| Service | URL | Credentials |
|---------|-----|-------------|
| Prometheus | `http://<node-ip>:30090` | — |
| Grafana | `http://192.168.100.10:30030` | admin / agk@2026! |

---

**Project**: agk Technical Assessment — Production-Grade Kubernetes on KVM
**Phase**: 4 — Monitoring, Logging & Backup
