#!/usr/bin/env bash
# =============================================================================
# irsa-setup.sh — Configure IRSA (IAM Roles for Service Accounts) for ArgoCD
#
# IRSA allows ArgoCD pods to assume an AWS IAM Role without storing
# credentials in Kubernetes Secrets.  Used for:
#   - Reading from private ECR (image pull)
#   - ArgoCD Notifications (SES email sending)
#   - Loki S3 bucket access
#   - External Secrets Operator (AWS Secrets Manager / SSM)
#
# Usage:
#   AWS_ACCOUNT_ID=123456789012 \
#   EKS_CLUSTER_NAME=my-eks-cluster \
#   AWS_REGION=us-east-1 \
#   ./scripts/irsa-setup.sh
#
# Prerequisites:
#   - AWS CLI configured with sufficient IAM permissions
#   - eksctl installed (for OIDC association)
#   - EKS cluster with OIDC provider enabled
# =============================================================================
set -euo pipefail

: "${AWS_ACCOUNT_ID:?Set AWS_ACCOUNT_ID}"
: "${EKS_CLUSTER_NAME:?Set EKS_CLUSTER_NAME}"
: "${AWS_REGION:?Set AWS_REGION}"

CYAN='\033[0;36m'; GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()  { echo -e "${GREEN}[OK]${NC}    $*"; }

# ------------------------------------------------------------------ #
# Step 1: Associate OIDC provider with EKS cluster                  #
# ------------------------------------------------------------------ #
log "Associating OIDC provider with EKS cluster: ${EKS_CLUSTER_NAME}"
eksctl utils associate-iam-oidc-provider \
  --cluster "${EKS_CLUSTER_NAME}" \
  --region  "${AWS_REGION}" \
  --approve
ok "OIDC provider associated"

# Retrieve the OIDC provider URL
OIDC_URL=$(aws eks describe-cluster \
  --name   "${EKS_CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query  "cluster.identity.oidc.issuer" \
  --output text | sed 's|https://||')
log "OIDC URL: ${OIDC_URL}"

# ------------------------------------------------------------------ #
# Step 2: Create IAM policy for ArgoCD (ECR + Secrets Manager)      #
# ------------------------------------------------------------------ #
log "Creating IAM policy for ArgoCD..."
aws iam create-policy \
  --policy-name "ArgoCD-IRSA-Policy-${EKS_CLUSTER_NAME}" \
  --policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Sid": "ECRReadOnly",
        "Effect": "Allow",
        "Action": [
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetAuthorizationToken"
        ],
        "Resource": "*"
      },
      {
        "Sid": "SecretsManagerReadOnly",
        "Effect": "Allow",
        "Action": [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ],
        "Resource": "arn:aws:secretsmanager:'"${AWS_REGION}"':'"${AWS_ACCOUNT_ID}"':secret:argocd/*"
      }
    ]
  }' || log "Policy may already exist, continuing..."
ok "IAM policy created"

POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/ArgoCD-IRSA-Policy-${EKS_CLUSTER_NAME}"

# ------------------------------------------------------------------ #
# Step 3: Create IAM Role with trust relationship for ArgoCD SA      #
# ------------------------------------------------------------------ #
log "Creating IAM Role for ArgoCD server service account..."
aws iam create-role \
  --role-name "ArgoCD-Server-Role-${EKS_CLUSTER_NAME}" \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Principal": {
          "Federated": "arn:aws:iam::'"${AWS_ACCOUNT_ID}"':oidc-provider/'"${OIDC_URL}"'"
        },
        "Action": "sts:AssumeRoleWithWebIdentity",
        "Condition": {
          "StringEquals": {
            "'"${OIDC_URL}"':sub": "system:serviceaccount:argocd:argocd-server",
            "'"${OIDC_URL}"':aud": "sts.amazonaws.com"
          }
        }
      }
    ]
  }' || log "Role may already exist, continuing..."

aws iam attach-role-policy \
  --role-name "ArgoCD-Server-Role-${EKS_CLUSTER_NAME}" \
  --policy-arn "${POLICY_ARN}"
ok "IAM Role created and policy attached"

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/ArgoCD-Server-Role-${EKS_CLUSTER_NAME}"

# ------------------------------------------------------------------ #
# Step 4: Annotate the ArgoCD ServiceAccount                        #
# ------------------------------------------------------------------ #
log "Annotating ArgoCD server ServiceAccount with IRSA role ARN..."
kubectl annotate serviceaccount argocd-server \
  -n argocd \
  eks.amazonaws.com/role-arn="${ROLE_ARN}" \
  --overwrite
ok "ServiceAccount annotated"

# ------------------------------------------------------------------ #
# Step 5: Restart ArgoCD server to pick up IRSA token               #
# ------------------------------------------------------------------ #
log "Restarting argocd-server deployment..."
kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-server -n argocd --timeout=120s
ok "ArgoCD server restarted with IRSA credentials"

echo ""
echo -e "${GREEN}IRSA setup complete!${NC}"
echo "Role ARN: ${ROLE_ARN}"
echo ""
echo "Verify IRSA is working:"
echo "  kubectl exec -it -n argocd deploy/argocd-server -- aws sts get-caller-identity"
