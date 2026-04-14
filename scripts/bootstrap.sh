#!/usr/bin/env bash
# =============================================================================
# bootstrap.sh — One-shot ArgoCD installation and GitOps bootstrap
#
# Usage:
#   chmod +x scripts/bootstrap.sh
#   ./scripts/bootstrap.sh [--env <dev|staging|prod>] [--dry-run]
#
# Prerequisites:
#   - kubectl configured and pointing at the target EKS cluster
#   - AWS CLI configured (for IRSA verification)
#   - helm v3 installed
#   - kustomize v5+ installed (or use kubectl apply -k)
#
# What this script does:
#   1. Verifies prerequisites
#   2. Installs ArgoCD via Kustomize (idempotent)
#   3. Waits for ArgoCD to be ready
#   4. Creates AppProjects (dev/staging/prod)
#   5. Applies the root App-of-Apps
#   6. Prints the initial admin password
# =============================================================================
set -euo pipefail

# ------------------------------------------------------------------ #
# Colours                                                            #
# ------------------------------------------------------------------ #
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; NC='\033[0m'

log()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}    $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ------------------------------------------------------------------ #
# Argument parsing                                                   #
# ------------------------------------------------------------------ #
ENV="all"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --env)    ENV="$2";  shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help)
      echo "Usage: $0 [--env dev|staging|prod|all] [--dry-run]"
      exit 0 ;;
    *) err "Unknown argument: $1" ;;
  esac
done

KUBECTL_OPTS=""
[[ "$DRY_RUN" == "true" ]] && KUBECTL_OPTS="--dry-run=client" && warn "DRY RUN mode — no changes will be applied"

# ------------------------------------------------------------------ #
# 1. Prerequisite checks                                             #
# ------------------------------------------------------------------ #
log "Checking prerequisites..."

for cmd in kubectl kustomize helm aws; do
  command -v "$cmd" &>/dev/null || err "$cmd is not installed or not in PATH"
done
ok "All prerequisite binaries found"

CONTEXT=$(kubectl config current-context 2>/dev/null) || err "kubectl is not configured"
log "Current kubectl context: ${CONTEXT}"

# Safety guard — prompt before modifying prod
if [[ "$ENV" == "prod" || "$ENV" == "all" ]]; then
  warn "You are about to bootstrap the PRODUCTION environment."
  read -r -p "Type 'yes-i-am-sure' to continue: " CONFIRM
  [[ "$CONFIRM" == "yes-i-am-sure" ]] || err "Aborted."
fi

# ------------------------------------------------------------------ #
# 2. Install ArgoCD via Kustomize                                    #
# ------------------------------------------------------------------ #
log "Installing ArgoCD (Kustomize)..."
kubectl apply -k manifests/argocd/ $KUBECTL_OPTS
ok "ArgoCD manifests applied"

# ------------------------------------------------------------------ #
# 3. Wait for ArgoCD components to be ready                         #
# ------------------------------------------------------------------ #
if [[ "$DRY_RUN" == "false" ]]; then
  log "Waiting for ArgoCD deployments to be ready (timeout: 300s)..."

  DEPLOYMENTS=(
    "argocd-server"
    "argocd-repo-server"
    "argocd-applicationset-controller"
    "argocd-notifications-controller"
  )

  for deploy in "${DEPLOYMENTS[@]}"; do
    log "  Waiting for deployment/${deploy}..."
    kubectl rollout status deployment/"${deploy}" \
      -n argocd \
      --timeout=300s
  done

  # StatefulSet for HA application controller
  kubectl rollout status statefulset/argocd-application-controller \
    -n argocd \
    --timeout=300s

  ok "All ArgoCD components are ready"
fi

# ------------------------------------------------------------------ #
# 4. Apply AppProjects                                               #
# ------------------------------------------------------------------ #
log "Applying AppProject definitions..."

apply_project() {
  local project_file="projects/${1}-project.yaml"
  [[ -f "$project_file" ]] || err "Project file not found: $project_file"
  kubectl apply -f "$project_file" -n argocd $KUBECTL_OPTS
  ok "  Applied project: $1"
}

case "$ENV" in
  dev)     apply_project dev ;;
  staging) apply_project staging ;;
  prod)    apply_project prod ;;
  all)
    apply_project dev
    apply_project staging
    apply_project prod
    ;;
esac

# ------------------------------------------------------------------ #
# 5. Bootstrap the root App-of-Apps                                 #
# ------------------------------------------------------------------ #
log "Applying root App-of-Apps..."
kubectl apply -f manifests/bootstrap/root-app.yaml $KUBECTL_OPTS
ok "Root App-of-Apps applied"

# ------------------------------------------------------------------ #
# 6. Print admin credentials                                        #
# ------------------------------------------------------------------ #
if [[ "$DRY_RUN" == "false" ]]; then
  echo ""
  log "Retrieving initial admin password..."
  ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret \
    -n argocd \
    -o jsonpath='{.data.password}' | base64 --decode)

  echo ""
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo -e "${GREEN}  ArgoCD Bootstrap Complete!               ${NC}"
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo -e "  Admin username : ${CYAN}admin${NC}"
  echo -e "  Admin password : ${CYAN}${ARGOCD_PASSWORD}${NC}"
  echo ""
  echo -e "  ${YELLOW}IMPORTANT:${NC} Change this password immediately:"
  echo -e "  argocd account update-password --current-password '${ARGOCD_PASSWORD}' --new-password '<NEW_PASSWORD>'"
  echo ""
  echo -e "  Access UI (port-forward for initial setup):"
  echo -e "  kubectl port-forward svc/argocd-server -n argocd 8080:443"
  echo -e "  Then open: ${CYAN}https://localhost:8080${NC}"
  echo -e "${GREEN}════════════════════════════════════════════${NC}"
  echo ""

  warn "Delete the initial admin secret once SSO is configured:"
  warn "  kubectl delete secret argocd-initial-admin-secret -n argocd"
fi
