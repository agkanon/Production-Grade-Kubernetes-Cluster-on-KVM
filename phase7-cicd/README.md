# Phase 7: CI/CD Pipeline

 — agk Technical Assessment
**Scope**: GitHub Actions pipeline — build, test, transfer images, rolling deploy
**Prerequisites**: Phase 3–5 complete, self-hosted runner on KVM hypervisor

---

## Pipeline Overview

```
Developer pushes to main
         │
         ▼
GitHub Actions Self-Hosted Runner (KVM Hypervisor)
Direct route to 192.168.1.0/24

Job 1: build
  ├── docker build → bmi-health/frontend:<SHA>
  ├── docker build → bmi-health/backend:<SHA>
  ├── docker build → bmi-health/database:<SHA>
  ├── backend unit test
  └── docker save | gzip → upload artifacts

Job 2: transfer (needs: build)
  ├── download artifacts
  ├── scp → 192.168.1.10/20/30
  └── ctr images import on each node

Job 3: deploy (needs: build, transfer)
  ├── kubectl apply updated manifests
  ├── kubectl rollout status
  ├── health check via port-forward
  └── on failure: kubectl rollout undo
```

## Setup Instructions

### Step 1 — Install self-hosted runner on hypervisor

```bash
docker --version || (curl -fsSL https://get.docker.com | sudo sh; sudo usermod -aG docker $USER)

mkdir -p ~/actions-runner && cd ~/actions-runner

# Download runner (get latest URL from GitHub repo Settings → Actions → Runners)
curl -o actions-runner-linux-x64.tar.gz -L \
  "https://github.com/actions/runner/releases/download/v2.316.0/actions-runner-linux-x64-2.316.0.tar.gz"
tar xzf actions-runner-linux-x64.tar.gz

# Register (paste token from GitHub UI)
./config.sh --url https://github.com/<YOUR_USERNAME>/<REPO> \
  --token <TOKEN> --name hypervisor-runner --labels self-hosted,linux,kvm --unattended

sudo ./svc.sh install
sudo ./svc.sh start
sudo ./svc.sh status
```

### Step 2 — Generate kubeconfig for pipeline

```bash
ssh ubuntu@192.168.1.10
sed 's/127.0.0.1/192.168.1.10/' ~/.kube/config | base64 -w 0
# Copy output for KUBE_CONFIG secret
```

### Step 3 — Add GitHub secrets

| Secret | Value |
|--------|-------|
| `SSH_PRIVATE_KEY` | Contents of `phase1-kvm-infrastructure/.ssh/id_rsa` |
| `KUBE_CONFIG` | base64-encoded kubeconfig from Step 2 |

### Step 4 — Create workflow file

Save the following as `.github/workflows/build-and-deploy.yml` in your repository:

```yaml
name: Build and Deploy BMI Tracker

on:
  push:
    branches: [main]
    paths:
      - 'phase3-application-deployment/**'
  workflow_dispatch:
    inputs:
      component:
        description: 'Component to deploy (all/frontend/backend/database)'
        required: false
        default: 'all'

env:
  IMAGE_TAG: ${{ github.sha }}
  DEPLOY_DIR: phase3-application-deployment
  CP01_IP: 192.168.1.10
  W01_IP:  192.168.1.20
  W02_IP:  192.168.1.30

jobs:
  build:
    name: Build Docker Images
    runs-on: self-hosted
    outputs:
      image_tag: ${{ env.IMAGE_TAG }}
    steps:
      - uses: actions/checkout@v4
      - run: docker build -t bmi-health/frontend:${{ env.IMAGE_TAG }} ${{ env.DEPLOY_DIR }}/frontend
      - run: docker build -t bmi-health/backend:${{ env.IMAGE_TAG }}  ${{ env.DEPLOY_DIR }}/backend
      - run: docker build -t bmi-health/database:${{ env.IMAGE_TAG }} ${{ env.DEPLOY_DIR }}/database
      - run: |
          docker run --rm bmi-health/backend:${{ env.IMAGE_TAG }} \
            node -e "
              const {calculateMetrics}=require('./src/calculations');
              const r=calculateMetrics({weightKg:70,heightCm:175,age:30,sex:'male',activity:'moderate'});
              if(r.bmi<10||r.bmi>60){console.error('BMI out of range:',r.bmi);process.exit(1);}
              console.log('BMI calculation OK:',r.bmi);
            "
      - run: |
          docker save bmi-health/frontend:${{ env.IMAGE_TAG }} | gzip > /tmp/bmi-frontend.tar.gz
          docker save bmi-health/backend:${{ env.IMAGE_TAG }}  | gzip > /tmp/bmi-backend.tar.gz
          docker save bmi-health/database:${{ env.IMAGE_TAG }} | gzip > /tmp/bmi-database.tar.gz
      - uses: actions/upload-artifact@v4
        with:
          name: docker-images-${{ env.IMAGE_TAG }}
          path: /tmp/bmi-*.tar.gz
          retention-days: 1

  transfer:
    name: Transfer Images to Cluster
    runs-on: self-hosted
    needs: build
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: docker-images-${{ needs.build.outputs.image_tag }}
          path: /tmp/images
      - run: |
          mkdir -p ~/.ssh
          echo "${{ secrets.SSH_PRIVATE_KEY }}" > ~/.ssh/ci_id_rsa
          chmod 600 ~/.ssh/ci_id_rsa
          ssh-keyscan -H ${{ env.CP01_IP }} ${{ env.W01_IP }} ${{ env.W02_IP }} >> ~/.ssh/known_hosts 2>/dev/null
      - run: |
          SSH="ssh -i ~/.ssh/ci_id_rsa"
          SCP="scp -i ~/.ssh/ci_id_rsa"
          for NODE in ${{ env.CP01_IP }} ${{ env.W01_IP }} ${{ env.W02_IP }}; do
            ${SCP} /tmp/images/bmi-*.tar.gz ubuntu@${NODE}:/tmp/
            ${SSH} ubuntu@${NODE} "
              for f in /tmp/bmi-*.tar.gz; do
                gunzip -c \"\$f\" | sudo ctr -n k8s.io images import --label io.cri-containerd.image=managed -
              done
              rm /tmp/bmi-*.tar.gz
            "
          done
      - run: rm -f ~/.ssh/ci_id_rsa
        if: always()

  deploy:
    name: Rolling Deploy to Kubernetes
    runs-on: self-hosted
    needs: [build, transfer]
    environment: production
    steps:
      - uses: actions/checkout@v4
      - run: |
          mkdir -p ~/.kube
          echo "${{ secrets.KUBE_CONFIG }}" | base64 -d > ~/.kube/config
          chmod 600 ~/.kube/config
          kubectl cluster-info
      - run: |
          TAG=${{ needs.build.outputs.image_tag }}
          sed -i "s|bmi-health/frontend:.*|bmi-health/frontend:${TAG}|g" ${{ env.DEPLOY_DIR }}/manifests/05-frontend.yaml
          sed -i "s|bmi-health/backend:.*|bmi-health/backend:${TAG}|g"  ${{ env.DEPLOY_DIR }}/manifests/04-backend.yaml
          sed -i "s|bmi-health/database:.*|bmi-health/database:${TAG}|g" ${{ env.DEPLOY_DIR }}/manifests/03-database.yaml
      - run: |
          kubectl apply -f ${{ env.DEPLOY_DIR }}/manifests/03-database.yaml
          kubectl apply -f ${{ env.DEPLOY_DIR }}/manifests/04-backend.yaml
          kubectl apply -f ${{ env.DEPLOY_DIR }}/manifests/05-frontend.yaml
      - run: |
          kubectl rollout status deployment/backend  -n production --timeout=180s
          kubectl rollout status deployment/frontend -n production --timeout=180s
      - run: |
          kubectl port-forward svc/backend-service 13000:3000 -n production &
          PF_PID=$!; sleep 5
          STATUS=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:13000/health)
          kill $PF_PID 2>/dev/null || true
          [ "$STATUS" = "200" ] || (echo "Health check failed"; exit 1)
      - run: |
          echo "Deploy failed — rolling back..."
          kubectl rollout undo deployment/backend  -n production
          kubectl rollout undo deployment/frontend -n production
          kubectl rollout status deployment/backend  -n production --timeout=120s
          kubectl rollout status deployment/frontend -n production --timeout=120s
        if: failure()
      - run: rm -f ~/.kube/config
        if: always()
```

### Step 5 — Push and trigger

```bash
git add .github/workflows/build-and-deploy.yml
git commit -m "ci: add build and deploy pipeline"
git push origin main
```

## Manual Trigger

```bash
gh workflow run build-and-deploy.yml -f component=backend
```

## Pipeline Security

| Risk | Mitigation |
|------|-----------|
| SSH key exposed | GitHub masks secrets |
| Kubeconfig gives cluster admin | Scope to limited ServiceAccount (see README notes) |
| Image tags overwritten | SHA tags are immutable |
| Manual approval bypassed | Add GitHub Environment protection rules |

---

**Project**: agk Technical Assessment — Production-Grade Kubernetes on KVM
**Phase**: 7 — CI/CD Pipeline
