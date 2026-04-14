# ArgoCD Production Setup Guide — AWS EKS

**Role:** Senior DevOps Architect  
**Target:** Production EKS Cluster  
**Repo:** `argocd-setup`  
**ArgoCD Version:** v2.11.0 (HA mode)

---

## Table of Contents

- [Pre-requisites](#pre-requisites)
- [Phase 0 — Pre-Flight Checks](#phase-0--pre-flight-checks)
- [Phase 1 — Prepare the Repository](#phase-1--prepare-the-repository)
- [Phase 2 — ACM Certificate](#phase-2--acm-certificate)
- [Phase 3 — IRSA Setup](#phase-3--irsa-setup)
- [Phase 4 — Install ArgoCD](#phase-4--install-argocd)
- [Phase 5 — First Login](#phase-5--first-login)
- [Phase 6 — Apply AppProjects](#phase-6--apply-appprojects)
- [Phase 7 — Bootstrap Root App](#phase-7--bootstrap-root-app)
- [Phase 8 — ALB Ingress & Route53](#phase-8--alb-ingress--route53)
- [Phase 9 — GitHub Webhook](#phase-9--github-webhook)
- [Phase 10 — End-to-End Verification](#phase-10--end-to-end-verification)
- [Phase 11 — Post-Installation Hardening](#phase-11--post-installation-hardening)
- [Full Sequence Summary](#full-sequence-summary)
- [Rollback Procedure](#rollback-procedure)
- [Troubleshooting](#troubleshooting)

---

## Pre-requisites

Ensure the following tools are installed and configured on your workstation before starting.

| Tool | Minimum Version | Install |
|---|---|---|
| kubectl | v1.28+ | `brew install kubectl` |
| kustomize | v5+ | `brew install kustomize` |
| helm | v3.12+ | `brew install helm` |
| argocd CLI | v2.11+ | `brew install argocd` |
| aws CLI | v2 | `brew install awscli` |
| eksctl | v0.180+ | `brew install eksctl` |
| gh CLI | v2+ | `brew install gh` |

**EKS cluster must have:**
- AWS Load Balancer Controller deployed
- OIDC provider associated
- `gp3` StorageClass available
- `external-dns` deployed (optional, for automatic DNS)

---

## Phase 0 — Pre-Flight Checks

> **Rule:** Never start installation until every check below passes. A failed check mid-install is harder to recover from than fixing it upfront.

### 0.1 Confirm you are on the correct cluster

```bash
kubectl config current-context
```

Expected output — must match your production cluster name:
```
arn:aws:eks:us-east-1:123456789012:cluster/my-prod-cluster
```

If wrong, switch context:
```bash
aws eks update-kubeconfig --name <CLUSTER_NAME> --region <REGION>
kubectl config current-context   # confirm again
```

### 0.2 Confirm cluster is ACTIVE

```bash
aws eks describe-cluster \
  --name <CLUSTER_NAME> \
  --region <REGION> \
  --query "cluster.status" \
  --output text
```

Expected: `ACTIVE`

### 0.3 Confirm AWS Load Balancer Controller is running

```bash
kubectl get deployment aws-load-balancer-controller -n kube-system
```

Expected:
```
NAME                           READY   UP-TO-DATE   AVAILABLE
aws-load-balancer-controller   2/2     2            2
```

> If missing, install it before proceeding:
> https://kubernetes-sigs.github.io/aws-load-balancer-controller/

### 0.4 Confirm OIDC provider is associated

```bash
aws eks describe-cluster \
  --name <CLUSTER_NAME> \
  --region <REGION> \
  --query "cluster.identity.oidc.issuer" \
  --output text
```

Expected: A URL like `https://oidc.eks.us-east-1.amazonaws.com/id/EXAMPLED539D4633E53DE1B71EXAMPLE`

> If empty, IRSA will not work. Associate it:
> ```bash
> eksctl utils associate-iam-oidc-provider \
>   --cluster <CLUSTER_NAME> \
>   --region <REGION> \
>   --approve
> ```

### 0.5 Confirm gp3 StorageClass exists

```bash
kubectl get storageclass gp3
```

Expected:
```
NAME   PROVISIONER             RECLAIMPOLICY   VOLUMEBINDINGMODE
gp3    ebs.csi.aws.com         Delete          WaitForFirstConsumer
```

> If missing, create it:
> ```bash
> kubectl apply -f - <<EOF
> apiVersion: storage.k8s.io/v1
> kind: StorageClass
> metadata:
>   name: gp3
> provisioner: ebs.csi.aws.com
> volumeBindingMode: WaitForFirstConsumer
> parameters:
>   type: gp3
>   encrypted: "true"
> EOF
> ```

### 0.6 Confirm IAM permissions

```bash
aws sts get-caller-identity
```

Your IAM user/role must have permissions to:
- Create IAM Roles and Policies
- Create/describe ACM certificates
- Manage Route53 records
- Describe EKS clusters

### 0.7 Confirm kubectl access to the cluster

```bash
kubectl get nodes
```

All nodes should show `Ready` status.

```bash
kubectl get nodes
# NAME                           STATUS   ROLES    AGE
# ip-10-0-1-100.ec2.internal     Ready    <none>   5d
# ip-10-0-2-200.ec2.internal     Ready    <none>   5d
```

---

## Phase 1 — Prepare the Repository

### 1.1 Clone the repo

```bash
git clone https://github.com/<YOUR_ORG>/argocd-setup
cd argocd-setup
```

### 1.2 Find all placeholders

```bash
grep -roh '<[A-Z_]*>' . --include="*.yaml" --include="*.sh" | sort -u
```

You will see:
```
<ACCOUNT_ID>
<CERT_ID>
<LOKI_BUCKET>
<REGION>
<YOUR_ORG>
```

### 1.3 Replace placeholders — file by file

**File: `manifests/argocd/argocd-cm.yaml`**

Find:
```yaml
- url: https://github.com/<YOUR_ORG>/argocd-setup
```
Replace with your real GitHub org:
```yaml
- url: https://github.com/acme-corp/argocd-setup
```

---

**File: `manifests/argocd/ingress.yaml`**

Replace the ACM ARN:
```yaml
alb.ingress.kubernetes.io/certificate-arn: arn:aws:acm:us-east-1:123456789012:certificate/xxxx-xxxx-xxxx
```

Replace the host:
```yaml
host: argocd.yourdomain.com
```

Replace the region and account in the WAF ARN (if using WAF):
```yaml
# alb.ingress.kubernetes.io/wafv2-acl-arn: arn:aws:wafv2:us-east-1:123456789012:regional/webacl/...
```

---

**File: `manifests/bootstrap/root-app.yaml`**

```yaml
repoURL: https://github.com/acme-corp/argocd-setup
```

---

**File: `applications/dev/app-of-apps.yaml`**

```yaml
repoURL: https://github.com/acme-corp/argocd-setup
```

---

**File: `applications/staging/app-of-apps.yaml`**

```yaml
repoURL: https://github.com/acme-corp/argocd-setup
```

---

**File: `applications/prod/app-of-apps.yaml`**

```yaml
repoURL: https://github.com/acme-corp/argocd-setup
```

---

**Files: `applications/*/monitoring.yaml` and `applications/*/loki.yaml`**

```yaml
repoURL: https://github.com/acme-corp/monitoring-stack
```

For prod loki, also replace the S3 bucket:
```yaml
s3: s3://us-east-1/my-loki-prod-bucket
```

---

**Files: `projects/dev-project.yaml`, `staging-project.yaml`, `prod-project.yaml`**

Replace all group references:
```yaml
# Before
- <YOUR_ORG>:platform-admins
- <YOUR_ORG>:devops-team
- <YOUR_ORG>:developers

# After (example with Okta groups)
- acme-corp:platform-admins
- acme-corp:devops-team
- acme-corp:developers
```

Also update source repo URLs in each project file.

### 1.4 Commit and push

```bash
git add .
git commit -m "config: replace all placeholders with production values"
git push origin main
```

---

## Phase 2 — ACM Certificate

You need a validated TLS certificate before the ALB Ingress will work.

### 2.1 Request the certificate

```bash
aws acm request-certificate \
  --domain-name argocd.yourdomain.com \
  --validation-method DNS \
  --region us-east-1
```

Note the `CertificateArn` from the output:
```json
{
    "CertificateArn": "arn:aws:acm:us-east-1:123456789012:certificate/xxxx-xxxx"
}
```

### 2.2 Get the DNS validation record

```bash
aws acm describe-certificate \
  --certificate-arn arn:aws:acm:us-east-1:123456789012:certificate/xxxx-xxxx \
  --query "Certificate.DomainValidationOptions[0].ResourceRecord"
```

Output:
```json
{
    "Name": "_abc123.argocd.yourdomain.com.",
    "Type": "CNAME",
    "Value": "_def456.acm-validations.aws."
}
```

### 2.3 Add the CNAME to Route53

```bash
aws route53 change-resource-record-sets \
  --hosted-zone-id <YOUR_HOSTED_ZONE_ID> \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "_abc123.argocd.yourdomain.com.",
        "Type": "CNAME",
        "TTL": 300,
        "ResourceRecords": [{"Value": "_def456.acm-validations.aws."}]
      }
    }]
  }'
```

### 2.4 Wait for validation

```bash
watch aws acm describe-certificate \
  --certificate-arn arn:aws:acm:us-east-1:123456789012:certificate/xxxx-xxxx \
  --query "Certificate.Status" \
  --output text
```

Wait until output is `ISSUED` (typically 1-5 minutes).

### 2.5 Update ingress.yaml with the certificate ARN

```bash
# Update manifests/argocd/ingress.yaml with the real ARN, commit and push
git add manifests/argocd/ingress.yaml
git commit -m "config: add ACM certificate ARN to ingress"
git push origin main
```

---

## Phase 3 — IRSA Setup

IRSA (IAM Roles for Service Accounts) gives ArgoCD pods AWS permissions using short-lived OIDC tokens. No static credentials anywhere.

### 3.1 Set environment variables

```bash
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export EKS_CLUSTER_NAME=my-prod-cluster
export AWS_REGION=us-east-1

echo "Account : $AWS_ACCOUNT_ID"
echo "Cluster : $EKS_CLUSTER_NAME"
echo "Region  : $AWS_REGION"
```

### 3.2 Run the IRSA setup script

```bash
chmod +x scripts/irsa-setup.sh
./scripts/irsa-setup.sh
```

This script performs:
1. Associates the OIDC provider with the EKS cluster
2. Creates IAM policy `ArgoCD-IRSA-Policy-<cluster>` (ECR read + Secrets Manager read)
3. Creates IAM Role `ArgoCD-Server-Role-<cluster>` with trust policy scoped to the `argocd-server` ServiceAccount only
4. Annotates the `argocd-server` ServiceAccount with the Role ARN

### 3.3 Verify IRSA configuration

After ArgoCD is installed (Phase 4), verify with:
```bash
kubectl exec -it -n argocd deploy/argocd-server -- \
  aws sts get-caller-identity
```

Expected: returns the ArgoCD IAM Role ARN, not your user ARN.

---

## Phase 4 — Install ArgoCD

### 4.1 Apply the Kustomize overlay

This single command installs ArgoCD HA v2.11.0 with all our ConfigMaps, resource limits, and namespace configuration:

```bash
kubectl apply -k manifests/argocd/
```

You will see output similar to:
```
namespace/argocd created
serviceaccount/argocd-application-controller created
serviceaccount/argocd-server created
configmap/argocd-cm configured
configmap/argocd-rbac-cm configured
configmap/argocd-cmd-params-cm configured
configmap/argocd-notifications-cm configured
deployment.apps/argocd-server created
deployment.apps/argocd-repo-server created
deployment.apps/argocd-applicationset-controller created
deployment.apps/argocd-notifications-controller created
statefulset.apps/argocd-application-controller created
...
```

### 4.2 Wait for all components to be ready

Run each command and wait for `successfully rolled out`:

```bash
kubectl rollout status deployment/argocd-server \
  -n argocd --timeout=300s

kubectl rollout status deployment/argocd-repo-server \
  -n argocd --timeout=300s

kubectl rollout status deployment/argocd-applicationset-controller \
  -n argocd --timeout=300s

kubectl rollout status deployment/argocd-notifications-controller \
  -n argocd --timeout=300s

kubectl rollout status statefulset/argocd-application-controller \
  -n argocd --timeout=300s
```

### 4.3 Confirm all pods are healthy

```bash
kubectl get pods -n argocd
```

Expected — every pod must show `Running`:
```
NAME                                                READY   STATUS    RESTARTS
argocd-application-controller-0                     1/1     Running   0
argocd-applicationset-controller-xxxx               1/1     Running   0
argocd-notifications-controller-xxxx                1/1     Running   0
argocd-redis-ha-xxxx                                2/2     Running   0
argocd-repo-server-xxxx                             1/1     Running   0
argocd-server-xxxx                                  1/1     Running   0
```

> If any pod is in `CrashLoopBackOff` or `Pending`, check:
> ```bash
> kubectl describe pod <pod-name> -n argocd
> kubectl logs <pod-name> -n argocd
> ```

---

## Phase 5 — First Login

### 5.1 Retrieve the initial admin password

```bash
./scripts/get-admin-password.sh
```

Or manually:
```bash
kubectl get secret argocd-initial-admin-secret \
  -n argocd \
  -o jsonpath='{.data.password}' | base64 --decode
```

### 5.2 Port-forward for initial access

> This is temporary — only for first login. Production access uses ALB Ingress (Phase 8).

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

Open `https://localhost:8080` in your browser.  
Accept the self-signed certificate warning.  
Login: username `admin`, password from above.

### 5.3 Login via CLI

```bash
argocd login localhost:8080 \
  --username admin \
  --password '<retrieved-password>' \
  --insecure
```

### 5.4 Change the admin password immediately

```bash
argocd account update-password \
  --current-password '<retrieved-password>' \
  --new-password '<strong-new-password-min-16-chars>'
```

> Use a password manager to generate and store the new password.

### 5.5 Verify login works with the new password

```bash
argocd logout localhost:8080
argocd login localhost:8080 \
  --username admin \
  --password '<new-password>' \
  --insecure
```

---

## Phase 6 — Apply AppProjects

AppProjects enforce environment isolation — RBAC, sync windows, and source repo restrictions.

### 6.1 Apply all three projects

```bash
kubectl apply -f projects/dev-project.yaml     -n argocd
kubectl apply -f projects/staging-project.yaml -n argocd
kubectl apply -f projects/prod-project.yaml    -n argocd
```

### 6.2 Verify projects were created

```bash
kubectl get appprojects -n argocd
```

Expected:
```
NAME      AGE
default   10m
dev       5s
prod      4s
staging   4s
```

### 6.3 Inspect each project

```bash
argocd proj get dev
argocd proj get staging
argocd proj get prod
```

Confirm sync windows are correct for each environment:

| Project | Sync Window |
|---|---|
| dev | Always open |
| staging | Mon-Fri 08:00-18:00 UTC |
| prod | Tue-Thu 10:00-14:00 UTC |

---

## Phase 7 — Bootstrap Root App

> **This is the most important step. Apply once. ArgoCD manages everything after.**

### 7.1 Apply the root App-of-Apps

```bash
kubectl apply -f manifests/bootstrap/root-app.yaml
```

### 7.2 Watch ArgoCD discover and create all child apps

```bash
kubectl get applications -n argocd -w
```

Within 30-60 seconds you should see:
```
NAME              SYNC STATUS   HEALTH STATUS
root-app          Synced        Healthy
dev-apps          Synced        Healthy
staging-apps      Synced        Healthy
prod-apps         OutOfSync     Healthy
monitoring-dev    Synced        Progressing
loki-dev          Synced        Progressing
monitoring-staging Synced       Progressing
loki-staging      Synced        Progressing
monitoring-prod   OutOfSync     Healthy
loki-prod         OutOfSync     Healthy
```

> `prod-apps` and prod applications show `OutOfSync` — this is **correct and expected**. Prod has no automated sync. A human must manually trigger sync within the change window.

### 7.3 Verify in the ArgoCD UI

In the UI at `https://localhost:8080` (or your domain after Phase 8), you should see the full application tree.

### 7.4 Force sync for dev and staging

```bash
argocd app sync dev-apps
argocd app sync staging-apps
```

Wait for `Synced / Healthy` on both.

---

## Phase 8 — ALB Ingress & Route53

### 8.1 Verify the Ingress was created

The ingress was already applied as part of Phase 4 (it is included in the Kustomize overlay). Check its status:

```bash
kubectl get ingress argocd-server-ingress -n argocd
```

> The ALB takes 2-5 minutes to provision. `ADDRESS` will be empty initially, then populate.

```
NAME                    CLASS   HOSTS                  ADDRESS                                                   PORTS
argocd-server-ingress   alb     argocd.yourdomain.com  k8s-argocd-xxxx.us-east-1.elb.amazonaws.com              80, 443
```

### 8.2 Create Route53 alias record

Get the ALB hosted zone ID for your region from AWS docs, then:

```bash
# Get the ALB DNS name
ALB_DNS=$(kubectl get ingress argocd-server-ingress -n argocd \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

echo "ALB DNS: $ALB_DNS"

# Create the Route53 alias record
aws route53 change-resource-record-sets \
  --hosted-zone-id <YOUR_HOSTED_ZONE_ID> \
  --change-batch "{
    \"Changes\": [{
      \"Action\": \"UPSERT\",
      \"ResourceRecordSet\": {
        \"Name\": \"argocd.yourdomain.com\",
        \"Type\": \"A\",
        \"AliasTarget\": {
          \"HostedZoneId\": \"Z35SXDOTRQ7X7K\",
          \"DNSName\": \"${ALB_DNS}\",
          \"EvaluateTargetHealth\": true
        }
      }
    }]
  }"
```

> **ALB Hosted Zone IDs by region:**
> - us-east-1: `Z35SXDOTRQ7X7K`
> - us-west-2: `Z1H1FL5HABSF5`
> - eu-west-1: `Z32O12XQLNTSW2`
> - ap-southeast-1: `Z1LMS91P8CMLE5`

### 8.3 Wait for DNS propagation

```bash
watch nslookup argocd.yourdomain.com
# Wait until it resolves to the ALB IP addresses
```

### 8.4 Test HTTPS access

```bash
curl -I https://argocd.yourdomain.com/healthz
```

Expected:
```
HTTP/2 200
content-type: text/plain; charset=utf-8
```

### 8.5 Update ArgoCD CLI to use the real URL

```bash
argocd login argocd.yourdomain.com \
  --username admin \
  --password '<new-password>'
# No --insecure flag needed — certificate is valid
```

---

## Phase 9 — GitHub Webhook

Webhooks replace the default 180-second poll cycle with near-real-time sync (< 5 seconds after a push).

### 9.1 Generate a webhook secret

```bash
WEBHOOK_SECRET=$(openssl rand -hex 32)
echo "Webhook Secret: $WEBHOOK_SECRET"
# Save this in your password manager
```

### 9.2 Store the secret in ArgoCD

```bash
kubectl patch secret argocd-secret -n argocd \
  --type='merge' \
  -p "{\"stringData\": {\"webhook.github.secret\": \"${WEBHOOK_SECRET}\"}}"
```

### 9.3 Configure the webhook in GitHub

1. Go to your `argocd-setup` GitHub repository
2. **Settings → Webhooks → Add webhook**
3. Fill in:

| Field | Value |
|---|---|
| Payload URL | `https://argocd.yourdomain.com/api/webhook` |
| Content type | `application/json` |
| Secret | `<WEBHOOK_SECRET from above>` |
| Events | `Push events` + `Pull request events` |
| Active | Checked |

4. Click **Add webhook**
5. GitHub sends a ping — check the **Recent Deliveries** tab. It should show `200`.

### 9.4 Verify webhook is working

Make a test commit to the repo:

```bash
echo "# webhook test" >> /tmp/test-webhook.txt
git add .
git commit --allow-empty -m "test: verify webhook sync"
git push origin main
```

Watch ArgoCD sync within seconds:

```bash
argocd app get root-app
# Conditions should show a recent sync timestamp
```

---

## Phase 10 — End-to-End Verification

### 10.1 Check all applications status

```bash
argocd app list
```

Expected:
```
NAME               CLUSTER    NAMESPACE  PROJECT  STATUS     HEALTH
root-app           in-cluster argocd     default  Synced     Healthy
dev-apps           in-cluster argocd     dev      Synced     Healthy
staging-apps       in-cluster argocd     staging  Synced     Healthy
prod-apps          in-cluster argocd     prod     OutOfSync  Healthy
monitoring-dev     in-cluster monitoring-dev  dev  Synced   Healthy
loki-dev           in-cluster logging-dev     dev  Synced   Healthy
monitoring-staging in-cluster monitoring-staging staging Synced Healthy
loki-staging       in-cluster logging-staging  staging Synced Healthy
monitoring-prod    in-cluster monitoring        prod OutOfSync Healthy
loki-prod          in-cluster logging           prod OutOfSync Healthy
```

### 10.2 Verify selfHeal is working (drift detection)

```bash
# Manually scale down a dev deployment (simulating drift)
kubectl scale deployment prometheus-operator \
  -n monitoring-dev --replicas=0

# Wait 30 seconds — ArgoCD should restore it automatically
sleep 30
kubectl get deployment prometheus-operator -n monitoring-dev
# READY should be back to 1/1
```

### 10.3 Verify sync window on prod

```bash
argocd app get monitoring-prod
# Look for: Sync Policy: Automated (Prune=false, SelfHeal=true)
# Sync Window: Deny all outside Tue-Thu 10-14 UTC

# Try to sync outside the window — it should be blocked
argocd app sync monitoring-prod
# Expected error: "Cannot sync: blocked by sync window"
```

### 10.4 Manually sync prod within the change window

> Only do this during Tue-Thu 10:00-14:00 UTC

```bash
argocd app sync monitoring-prod --prune=false
argocd app wait monitoring-prod --health --timeout 300
```

### 10.5 Test RBAC — developer should be read-only on prod

```bash
# Login as a developer user (if SSO is configured)
argocd login argocd.yourdomain.com --sso

# Attempt to sync a prod application — should be denied
argocd app sync monitoring-prod
# Expected: PermissionDenied
```

### 10.6 Verify Slack notifications

```bash
# Trigger a sync failure to test alerting
argocd app sync monitoring-dev --revision invalid-branch-xxxx
# Check #platform-alerts Slack channel for the failure notification
```

---

## Phase 11 — Post-Installation Hardening

### 11.1 Delete the initial admin secret

Once you have SSO configured or have saved the new password securely:

```bash
kubectl delete secret argocd-initial-admin-secret -n argocd
```

Verify it is gone:
```bash
kubectl get secret argocd-initial-admin-secret -n argocd
# Error from server (NotFound)
```

### 11.2 Confirm anonymous access is disabled

```bash
curl -s https://argocd.yourdomain.com/api/v1/applications \
  -o /dev/null -w "%{http_code}"
# Must return: 401
```

### 11.3 Confirm ArgoCD is not reachable without TLS

```bash
curl -s http://argocd.yourdomain.com/healthz \
  -o /dev/null -w "%{http_code}"
# Must return: 301 (redirected to HTTPS) or 403
```

### 11.4 Lock the argocd namespace with Pod Security Admission

```bash
kubectl label namespace argocd \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted \
  --overwrite

# Verify
kubectl get namespace argocd --show-labels
```

### 11.5 Confirm no one can exec into ArgoCD pods from prod project

```bash
# Try exec via ArgoCD CLI using a non-admin role
argocd app exec monitoring-prod -- /bin/sh
# Expected: PermissionDenied (exec is blocked in prod-project.yaml)
```

### 11.6 Set up repository access with a read-only Deploy Key

```bash
# Generate a dedicated deploy key (do NOT reuse personal SSH keys)
ssh-keygen -t ed25519 \
  -f ~/.ssh/argocd-deploy-key \
  -C "argocd-prod@yourdomain.com" \
  -N ""

echo "=== Public key (add to GitHub) ==="
cat ~/.ssh/argocd-deploy-key.pub
```

1. Go to GitHub `argocd-setup` repo → **Settings → Deploy Keys → Add deploy key**
2. Paste the **public key**
3. Name it `ArgoCD Production (read-only)`
4. Leave **Allow write access** unchecked

Register the repo in ArgoCD using the private key:

```bash
argocd repo add git@github.com:<YOUR_ORG>/argocd-setup \
  --ssh-private-key-path ~/.ssh/argocd-deploy-key \
  --name argocd-setup \
  --insecure-skip-server-verification=false

# Verify repo is connected
argocd repo list
```

### 11.7 Back up argocd-secret to AWS Secrets Manager

The `argocd-secret` contains repo credentials, SSO config, and webhook secrets. Back it up:

```bash
# Export the secret
kubectl get secret argocd-secret -n argocd -o json | \
  jq '.data | map_values(@base64d)' > /tmp/argocd-secret-backup.json

# Store in AWS Secrets Manager (not in Git)
aws secretsmanager create-secret \
  --name "prod/argocd/argocd-secret" \
  --description "ArgoCD master secret — backup" \
  --secret-string file:///tmp/argocd-secret-backup.json \
  --region us-east-1

# Delete the local file immediately
rm /tmp/argocd-secret-backup.json
```

### 11.8 Enable EKS control plane audit logging

```bash
aws eks update-cluster-config \
  --name <CLUSTER_NAME> \
  --region <REGION> \
  --logging '{"clusterLogging":[{"types":["audit","api","authenticator"],"enabled":true}]}'
```

This logs every `kubectl apply` ArgoCD makes — full audit trail in CloudWatch.

### 11.9 Configure SSO (recommended — disables local admin login)

Uncomment and fill the OIDC block in `manifests/argocd/argocd-cm.yaml`:

```yaml
url: https://argocd.yourdomain.com
oidc.config: |
  name: Okta
  issuer: https://your-org.okta.com/oauth2/default
  clientID: 0oa1abc2defGHIJK3456
  clientSecret: $oidc.okta.clientSecret
  requestedScopes: ["openid", "profile", "email", "groups"]
  requestedIDTokenClaims:
    groups:
      essential: true
```

Store the OIDC client secret in the cluster (not in Git):

```bash
kubectl patch secret argocd-secret -n argocd \
  --type='merge' \
  -p '{"stringData": {"oidc.okta.clientSecret": "<your-client-secret>"}}'
```

Apply the config change:

```bash
git add manifests/argocd/argocd-cm.yaml
git commit -m "config: enable OIDC SSO"
git push origin main
# ArgoCD will pick up the change via webhook and apply it
```

---

## Full Sequence Summary

```
PHASE   ACTION                                            TIME ESTIMATE
──────────────────────────────────────────────────────────────────────
0       Pre-flight checks                                 15 min
1       Replace placeholders, commit, push                20 min
2       Request ACM cert, add DNS CNAME, wait for ISSUED  10 min + wait
3       ./scripts/irsa-setup.sh                           5 min
4       kubectl apply -k manifests/argocd/               10 min
        Wait for all pods Running
5       ./scripts/get-admin-password.sh                   2 min
        First login, change password
6       kubectl apply -f projects/                        2 min
7       kubectl apply -f manifests/bootstrap/root-app.yaml  5 min
        Watch apps appear (ONE TIME ONLY)
8       ALB Ingress + Route53 record                      10 min + DNS propagation
9       GitHub Webhook setup                              5 min
10      End-to-end verification                           20 min
11      Post-installation hardening                       30 min
──────────────────────────────────────────────────────────────────────
TOTAL                                                     ~2-3 hours
```

After Phase 7, **Git is the only control plane for all application deployments.**  
No one runs `kubectl apply` for app changes — they open a Pull Request.

---

## Rollback Procedure

### Rollback an application to previous version

```bash
# View sync history
argocd app history monitoring-prod

# Roll back to a specific revision
argocd app rollback monitoring-prod <REVISION_ID>
```

Or via Git (preferred):
```bash
git revert HEAD
git push origin main
# ArgoCD detects the revert and syncs automatically (dev/staging)
# For prod: merge the revert PR, then manually sync
```

### Rollback ArgoCD itself

```bash
# Edit install-kustomization.yaml to the previous version
# Change: newTag: v2.11.0 → newTag: v2.10.0
git add manifests/argocd/install-kustomization.yaml
git commit -m "revert: argocd downgrade to v2.10.0"
git push origin main
kubectl apply -k manifests/argocd/
kubectl rollout status deployment/argocd-server -n argocd
```

---

## Troubleshooting

### ArgoCD pods not starting

```bash
kubectl describe pod <pod-name> -n argocd
# Common causes:
# - Insufficient CPU/memory on nodes → check node capacity
# - PodSecurityAdmission violations → check namespace labels
# - ImagePullBackOff → check ECR permissions / IRSA setup
```

### OutOfSync but Git changes are present

```bash
# Force a re-fetch from Git
argocd app get <app-name> --hard-refresh

# If still stuck, check repo-server logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=100
```

### Sync blocked by sync window

```bash
# Check active windows
argocd app get <app-name> | grep -A3 "Sync Window"

# Emergency override (admin only — use only in incident response)
argocd app sync <app-name> --force
```

### Application stuck in Progressing

```bash
# Check pod events in the target namespace
kubectl get events -n <namespace> --sort-by='.lastTimestamp' | tail -20

# Check for PVC pending (common with Loki/Prometheus)
kubectl get pvc -n <namespace>

# Check app controller logs
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-application-controller --tail=100
```

### Cannot connect to Git repository

```bash
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-repo-server --tail=50
# Common causes:
# - SSH key not registered → argocd repo add ...
# - Network policy blocking egress port 22/443
# - Wrong repoURL format (https vs ssh)
```

### ALB not provisioning

```bash
kubectl describe ingress argocd-server-ingress -n argocd
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
# Common causes:
# - Load Balancer Controller not running
# - Missing ACM cert ARN in ingress annotation
# - Subnet tags missing: kubernetes.io/role/elb=1
```

---

*Document version: 1.0 | Maintained by Platform Engineering*
