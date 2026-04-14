#!/usr/bin/env bash
# =============================================================================
# get-admin-password.sh — Safely retrieve the ArgoCD initial admin password
#
# Usage:
#   chmod +x scripts/get-admin-password.sh
#   ./scripts/get-admin-password.sh
#
# Notes:
#   - This secret only exists before SSO / password rotation.
#   - Once you configure SSO, delete this secret:
#       kubectl delete secret argocd-initial-admin-secret -n argocd
#   - In production, use AWS Secrets Manager + External Secrets Operator
#     to manage credentials rather than the initial secret.
# =============================================================================
set -euo pipefail

NAMESPACE="argocd"
SECRET_NAME="argocd-initial-admin-secret"

if ! kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "Secret '${SECRET_NAME}' not found in namespace '${NAMESPACE}'."
  echo "This likely means SSO is already configured and the secret was deleted."
  exit 1
fi

PASSWORD=$(kubectl get secret "$SECRET_NAME" \
  -n "$NAMESPACE" \
  -o jsonpath='{.data.password}' | base64 --decode)

echo ""
echo "ArgoCD Admin Credentials"
echo "========================"
echo "Username : admin"
echo "Password : ${PASSWORD}"
echo ""
echo "Next steps:"
echo "  1. Port-forward:  kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "  2. Open:          https://localhost:8080"
echo "  3. Login and change the password immediately."
echo "  4. Configure SSO (OIDC), then delete this secret."
