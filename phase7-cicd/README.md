# Phase 7: CI/CD Pipeline

 — agk Technical Assessment
**Scope**: GitHub Actions CI/CD pipeline — build, push to registry, rolling deploy
**Prerequisites**: Phase 3–5 complete, Docker Hub account, kubeconfig from cluster

---

## Pipeline Overview

The pipeline runs on every push to `main` (and pull requests to `main`) and consists of three jobs:

```
push to main
     │
     ▼
Job 1: build-and-test (ubuntu-latest)
  docker build phase3-application-deployment/backend   → bmi-backend:<SHA>
  docker build phase3-application-deployment/frontend  → bmi-frontend:<SHA>
  docker run --rm bmi-backend:<SHA> node --version    (smoke test)
     │
     ▼
Job 2: push-images (only on push to main)
  docker/login-action → Docker Hub
  docker/build-push-action → tag and push :<SHA> and :latest
     │
     ▼
Job 3: deploy (only on push to main)
  kubectl set image deployment/backend  → new SHA tag
  kubectl set image deployment/frontend → new SHA tag
  kubectl rollout status → wait for success
  on failure: kubectl rollout undo (automatic rollback)
```

### Job 1 — build-and-test

Runs on every push and pull request. Builds both Docker images and runs a smoke test (`node --version`) inside the backend image to catch basic failures early.

### Job 2 — push-images

Only on push to `main`. Logs in to Docker Hub using GitHub Secrets (`DOCKERHUB_USERNAME`, `DOCKERHUB_TOKEN`) and pushes images tagged with the commit SHA and `latest`.

### Job 3 — deploy

Only on push to `main`. Uses `kubectl set image` to update each Deployment to the newly built image tag, then monitors `rollout status`. If the rollout fails or times out, the pipeline automatically runs `kubectl rollout undo` to revert to the previous version.

---

## Required GitHub Repository Secrets

| Secret | Description |
|--------|-------------|
| `DOCKERHUB_USERNAME` | Docker Hub username for image push |
| `DOCKERHUB_TOKEN` | Docker Hub access token (not password) |
| `KUBE_CONFIG` | Base64-encoded kubeconfig from the cluster control plane |

### Setting up KUBE_CONFIG

```bash
# On cp-01 (control plane node)
sed 's/127.0.0.1/192.168.1.10/' ~/.kube/config | base64 -w 0

# Copy the output and add it as a GitHub repository secret named KUBE_CONFIG
```

---

## Automated Rollback

If any `kubectl rollout status` command fails (e.g., new pods crash-loop, readiness probe fails, timeout exceeded), the `Rollback on failure` step executes:

```bash
kubectl rollout undo deployment/backend -n production
kubectl rollout undo deployment/frontend -n production
```

This reverts the Deployment to the previous ReplicaSet, restoring the last known-good version. The workflow then exits with a failure status to alert the team.

---

## What Would Be Added With More Time

- **Image vulnerability scanning** — Integrate Trivy or Snyk into the build job to block pushes with critical CVEs
- **Staging environment** — A separate namespace or cluster with a manual approval gate before production deploy
- **Helm-based deployments** — Replace `kubectl set image` with Helm upgrades, enabling versioned releases and one-command rollbacks with `helm rollback`
- **Database migrations** — Run `npm run migrate` as a pre-deploy job or init container to apply schema changes before the new backend starts
- **Slack/email notifications** — Notify the team on deploy success or failure

---

## Triggering the Pipeline

```bash
# Push to main triggers the full pipeline
git push origin main

# Manual trigger via GitHub CLI
gh workflow run ci-cd.yml
```
