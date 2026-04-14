# ArgoCD GitOps Setup — Production-Grade EKS

A production-ready GitOps implementation using **ArgoCD** on **AWS EKS**, following real-world DevOps standards with multi-environment isolation, security best practices, and CI/CD integration.

---

## Table of Contents

1. [Repository Structure](#1-repository-structure)
2. [Architecture Overview](#2-architecture-overview)
3. [Prerequisites](#3-prerequisites)
4. [Quick Start](#4-quick-start)
5. [ArgoCD Installation](#5-argocd-installation)
6. [Accessing ArgoCD UI](#6-accessing-argocd-ui)
7. [Multi-Environment Design](#7-multi-environment-design)
8. [App of Apps Pattern](#8-app-of-apps-pattern)
9. [Security Best Practices](#9-security-best-practices)
10. [CI/CD Integration with Jenkins](#10-cicd-integration-with-jenkins)
11. [Promotion Workflow](#11-promotion-workflow)
12. [Monitoring & Alerting](#12-monitoring--alerting)
13. [Production Recommendations](#13-production-recommendations)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. Repository Structure

```
argocd-setup/
├── manifests/
│   ├── argocd/
│   │   ├── namespace.yaml              # argocd namespace with PSA labels
│   │   ├── argocd-cm.yaml              # Core ArgoCD configuration
│   │   ├── argocd-rbac-cm.yaml         # RBAC policy (admin/devops/developer/readonly)
│   │   ├── argocd-cmd-params-cm.yaml   # Server & controller tuning flags
│   │   ├── argocd-notifications-cm.yaml # Slack/PagerDuty alert templates
│   │   ├── ingress.yaml                # AWS ALB Ingress for HTTPS UI access
│   │   └── install-kustomization.yaml  # Kustomize overlay (pin version, set limits)
│   └── bootstrap/
│       └── root-app.yaml               # Single entry-point: the App-of-Apps root
│
├── applications/
│   ├── dev/
│   │   ├── app-of-apps.yaml            # Manages all dev/* Application CRs
│   │   ├── monitoring.yaml             # kube-prometheus-stack (dev)
│   │   └── loki.yaml                   # Loki log aggregation (dev)
│   ├── staging/
│   │   ├── app-of-apps.yaml
│   │   ├── monitoring.yaml
│   │   └── loki.yaml
│   └── prod/
│       ├── app-of-apps.yaml            # No automated sync — human-gated
│       ├── monitoring.yaml             # Pinned to Git tag, not branch
│       └── loki.yaml
│
├── projects/
│   ├── dev-project.yaml                # AppProject: open sync windows, broad permissions
│   ├── staging-project.yaml            # AppProject: Mon-Fri business hours only
│   └── prod-project.yaml               # AppProject: Tue-Thu, change-window only
│
└── scripts/
    ├── bootstrap.sh                    # One-shot install + bootstrap
    ├── get-admin-password.sh           # Retrieve initial admin secret
    ├── promote.sh                      # GitOps promotion: dev → staging → prod
    └── irsa-setup.sh                   # Configure AWS IRSA for ArgoCD pods
```

---

## 2. Architecture Overview

```
GitHub (argocd-setup)
        │
        │  Git webhook / poll
        ▼
┌─────────────────────────────────────────────────────┐
│                  ArgoCD (argocd ns)                 │
│                                                     │
│  root-app ──────────────────────────────────────┐  │
│    ├─► dev-apps ──► monitoring-dev, loki-dev    │  │
│    ├─► staging-apps ► monitoring-staging, …     │  │
│    └─► prod-apps ──► monitoring-prod, …         │  │
│                    (manual sync gate)            │  │
└─────────────────────┬───────────────────────────┘  │
                      │ kubectl apply                  │
         ┌────────────┼────────────┐                  │
         ▼            ▼            ▼                   │
    [dev-* ns]  [staging-* ns]  [prod-* ns]           │
```

**Key design decisions:**

| Decision | Rationale |
|---|---|
| App-of-Apps pattern | Single bootstrap point; Git is the source of truth for which apps exist |
| Kustomize for install | Idempotent; version-pins upstream; no Helm dependency for ArgoCD itself |
| Per-environment AppProjects | RBAC isolation; sync windows; separate source repo allowlists |
| Branch tracking in dev | Fast iteration; always pulls latest from `main` |
| Tag pinning in prod | Immutable deployments; reproducible rollbacks |
| ALB Ingress + ACM | TLS termination outside the cluster; no certificate management inside |
| IRSA (not static secrets) | IAM credentials auto-rotate; no long-lived access keys |

---

## 3. Prerequisites

| Tool | Version | Purpose |
|---|---|---|
| kubectl | v1.28+ | Cluster interaction |
| kustomize | v5+ | ArgoCD overlay |
| helm | v3.12+ | Application charts |
| argocd CLI | v2.11+ | Management & promotion |
| aws CLI | v2 | IRSA, ECR, Secrets Manager |
| eksctl | v0.180+ | OIDC provider association |
| gh CLI | v2+ | PR-based promotion |

**EKS requirements:**
- OIDC provider enabled on the cluster
- AWS Load Balancer Controller installed (for ALB Ingress)
- `gp3` StorageClass available (for Loki/Prometheus PVCs)
- `external-dns` configured (for automatic Route53 A-record creation)

---

## 4. Quick Start

```bash
# 1. Clone this repo
git clone https://github.com/<YOUR_ORG>/argocd-setup
cd argocd-setup

# 2. Point kubeconfig at your EKS cluster
aws eks update-kubeconfig --name <CLUSTER_NAME> --region <REGION>

# 3. Replace all placeholders before applying anything
grep -roh '<[A-Z_]*>' . --include="*.yaml" --include="*.sh" | sort -u

# 4. Run the bootstrap script
chmod +x scripts/*.sh
./scripts/bootstrap.sh --env all

# 5. Retrieve the initial admin password
./scripts/get-admin-password.sh

# 6. Port-forward for first login (switch to ALB Ingress after)
kubectl port-forward svc/argocd-server -n argocd 8080:443
# Open: https://localhost:8080
```

---

## 5. ArgoCD Installation

ArgoCD is installed via **Kustomize** — idempotent, version-pinned, no upstream manifest forking.

### Manual steps

```bash
# Install ArgoCD (HA mode, v2.11.0)
kubectl apply -k manifests/argocd/

# Wait for readiness
kubectl rollout status deployment/argocd-server          -n argocd --timeout=300s
kubectl rollout status deployment/argocd-repo-server     -n argocd --timeout=300s
kubectl rollout status statefulset/argocd-application-controller -n argocd --timeout=300s

# Apply AppProjects
kubectl apply -f projects/ -n argocd

# Bootstrap the root App-of-Apps (apply once — ArgoCD self-manages after)
kubectl apply -f manifests/bootstrap/root-app.yaml
```

### Why Kustomize?

- **Version pinning** — exact ArgoCD version locked in `install-kustomization.yaml`
- **Idempotent** — safe to re-apply at any time
- **Layered config** — ConfigMaps merged with upstream, no copy-paste maintenance
- **Resource limits** — CPU/memory patched in without forking the upstream manifest

---

## 6. Accessing ArgoCD UI

### Option A: Port-Forward (initial setup only)

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
# https://localhost:8080  |  user: admin  |  pass: see below
kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d
```

> Not for production — use ALB Ingress below.

### Option B: AWS ALB Ingress (production)

1. Fill in your ACM certificate ARN and domain in [manifests/argocd/ingress.yaml](manifests/argocd/ingress.yaml)
2. `kubectl apply -f manifests/argocd/ingress.yaml`
3. Create a Route53 alias record pointing to the ALB DNS name

Features: ACM TLS termination, TLS 1.3 policy, SSL redirect, optional WAF WebACL, IP allowlisting.

### Option C: Internal ALB (enterprise / VPN-only)

Set `alb.ingress.kubernetes.io/scheme: internal` — UI never exposed to the internet.

### Security: delete the initial secret after SSO setup

```bash
kubectl delete secret argocd-initial-admin-secret -n argocd
```

---

## 7. Multi-Environment Design

### Per-environment AppProject controls

| Control | dev | staging | prod |
|---|---|---|---|
| Source repos | Wildcards | Named only | Named only |
| Destination namespaces | `dev-*` | `staging-*` | `prod-*` |
| Sync windows | Always open | Mon-Fri 08-18 UTC | Tue-Thu 10-14 UTC |
| Automated prune | Yes | Yes | **No** (manual) |
| Exec / port-forward | Allowed | Allowed | **Denied** |

### targetRevision strategy

| Environment | targetRevision | Why |
|---|---|---|
| dev | `main` | Fast iteration, always latest |
| staging | `main` | Follows dev, pre-release validation |
| prod | `v1.2.3` (tag) | Immutable, reproducible, human-promoted |

---

## 8. App of Apps Pattern

One manual `kubectl apply` bootstraps the entire platform:

```
kubectl apply -f manifests/bootstrap/root-app.yaml
                        │
                        ▼  ArgoCD takes over
            applications/
            ├── dev/app-of-apps.yaml   → creates dev-apps  → monitoring-dev, loki-dev
            ├── staging/app-of-apps.yaml → staging-apps    → monitoring-staging, loki-staging
            └── prod/app-of-apps.yaml  → prod-apps         → monitoring-prod, loki-prod
```

**Adding a new app:** create `applications/<env>/new-app.yaml`, push to `main` — ArgoCD picks it up automatically.

---

## 9. Security Best Practices

### No secrets in Git

| Secret type | Where it lives |
|---|---|
| Git repo credentials | `argocd-secret` (K8s Secret, not in Git) |
| ECR image pull | IRSA — no static credentials |
| App secrets (DB, API keys) | AWS Secrets Manager via External Secrets Operator |
| TLS certificates | AWS ACM (auto-renewed) |
| SSO client secret | `argocd-secret` K8s Secret |

### IRSA — IAM Roles for Service Accounts

```bash
./scripts/irsa-setup.sh
```

ArgoCD pods assume an IAM Role via OIDC — short-lived tokens, auto-rotation, no `aws_access_key_id` anywhere.

### External Secrets Operator pattern

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: db-credentials
  namespace: prod-backend
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: aws-secrets-manager
    kind: ClusterSecretStore
  target:
    name: db-credentials
    creationPolicy: Owner
  data:
    - secretKey: password
      remoteRef:
        key: prod/backend/database
        property: password
```

### ArgoCD RBAC roles

| Role | Group | Permissions |
|---|---|---|
| `admin` | `platform-admins` | Full access |
| `devops` | `devops-team` | Sync all apps, manage repos |
| `developer` | `developers` | Sync dev/staging, read prod |
| `readonly` | All authenticated | Read-only (default) |

---

## 10. CI/CD Integration with Jenkins

### Principle: Jenkins builds, ArgoCD deploys

```
Jenkins
├── Terraform stage  → provisions EKS, VPC, IAM  (infrastructure)
└── Build stage      → builds image → pushes to ECR
                     → updates tag in applications/<env>/<app>.yaml
                     → commits to Git
                          │
                          ▼
                       ArgoCD detects change → syncs cluster
                       (no kubectl in Jenkins for app deploys)
```

### Jenkinsfile snippet

```groovy
stage('Update GitOps Manifest') {
  steps {
    sh """
      sed -i "s|tag:.*|tag: ${NEW_TAG}|" applications/dev/${APP_NAME}.yaml
      git add applications/dev/${APP_NAME}.yaml
      git commit -m "ci: update ${APP_NAME} to ${NEW_TAG} in dev"
      git push origin main
    """
    // ArgoCD auto-syncs dev. Staging/prod require promote.sh + PR.
  }
}
```

### Why not `kubectl` from Jenkins?

| Direct kubectl | GitOps via ArgoCD |
|---|---|
| No audit trail | Full Git history |
| Drift goes undetected | Drift auto-corrected (selfHeal) |
| Rollback = re-run pipeline | Rollback = `git revert` + merge |
| Credentials in Jenkins | No cluster credentials in Jenkins |

---

## 11. Promotion Workflow

```
Jenkins updates dev tag → ArgoCD auto-syncs dev
        │
        ▼  (QA signs off)
./scripts/promote.sh --app monitoring --from dev --to staging --version v1.2.3
        │  Opens GitHub PR
        ▼
DevOps reviews + merges → ArgoCD syncs staging (within sync window)
        │
        ▼  (UAT passes)
./scripts/promote.sh --app monitoring --from staging --to prod --version v1.2.3
        │  Opens GitHub PR (requires platform-admins approval)
        ▼
Senior engineer merges → manually syncs in ArgoCD UI (change window only)
        │
        ▼
Production deployment complete ✓
```

---

## 12. Monitoring & Alerting

### kube-prometheus-stack (per environment)

- **Prometheus** — metrics + alerting rules
- **Grafana** — dashboards (ArgoCD dashboard ID: `14584`)
- **AlertManager** — Slack / PagerDuty routing

### Loki (per environment)

- **Loki** — log storage (local PVC in dev, S3 in prod)
- **Promtail** — DaemonSet log shipper on all nodes

### ArgoCD Notifications

| Event | dev / staging channel | prod channel |
|---|---|---|
| Sync failed | `#platform-alerts` | `#platform-critical` |
| Health degraded | `#platform-alerts` | `#platform-critical` |
| Deployed successfully | `#platform-alerts` | `#platform-releases` |

---

## 13. Production Recommendations

| Recommendation | Why |
|---|---|
| HA ArgoCD install | Eliminates single point of failure |
| Git webhooks over polling | Reduces sync latency from ~3 min to seconds |
| Read-only Deploy Keys per repo | Least-privilege; one key breach doesn't expose all repos |
| EKS audit logging enabled | Track every API call including ArgoCD's applies |
| Back up `argocd-secret` to AWS Secrets Manager | Cluster state alone is not a backup |
| Use ApplicationSet for many similar apps | Templated apps across clusters/environments |
| Pin ArgoCD version; upgrade via PR | Controlled upgrades follow the same GitOps flow |

---

## 14. Troubleshooting

### OutOfSync but changes are in Git

```bash
argocd app get <app-name> --refresh       # Re-fetch from Git
argocd app get <app-name> --hard-refresh  # Clear repo-server cache
```

### Sync window blocking an urgent fix

```bash
argocd app sync <app-name> --force        # Override window (admin only)
```

### Application stuck in Progressing

```bash
kubectl get events -n <namespace> --sort-by='.lastTimestamp'
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=100
```

### Repo server cannot reach GitHub

```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100
# Common causes: SSH key not configured, egress NetworkPolicy blocking port 443/22
```

---

## Placeholders to Replace Before Use

```bash
# Find all placeholders
grep -roh '<[A-Z_]*>' . --include="*.yaml" --include="*.sh" | sort -u
```

| Placeholder | Replace with |
|---|---|
| `<YOUR_ORG>` | GitHub organization name |
| `<REGION>` | AWS region (e.g. `us-east-1`) |
| `<ACCOUNT_ID>` | 12-digit AWS account ID |
| `<CERT_ID>` | ACM certificate ID |
| `argocd.example.com` | Your ArgoCD FQDN |
| `<LOKI_BUCKET>` | S3 bucket name for Loki |
| `<YOUR_ORG>:platform-admins` | Your IdP group path |

---

*Maintained by the Platform Engineering team.*
