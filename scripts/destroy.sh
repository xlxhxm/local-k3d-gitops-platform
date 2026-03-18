#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# destroy.sh — Clean teardown of the local k3d GitOps platform
#
# Handles Argo CD CRD finalizers, stuck namespaces, and Terraform state
# so nothing hangs indefinitely.
#
# Usage:
#   ./scripts/destroy.sh              # full teardown (Terraform + k3d)
#   ./scripts/destroy.sh --keep-cluster  # Terraform only, keep k3d cluster
# ---------------------------------------------------------------------------

set -euo pipefail

# ── Configuration ──────────────────────────────────────────────────────────

CLUSTER_NAME="gitops-cluster"
KUBE_CONTEXT="k3d-${CLUSTER_NAME}"
TERRAFORM_DIR="$(cd "$(dirname "$0")/../terraform" && pwd)"
ARGOCD_NS="argocd"
APP_NAMESPACES=("infrastructure" "applications")
TIMEOUT=30   # seconds to wait for graceful operations

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ── Helpers ────────────────────────────────────────────────────────────────

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }

cluster_exists() {
  k3d cluster list -o json 2>/dev/null | grep -q "\"name\":\"${CLUSTER_NAME}\"" 2>/dev/null
}

kube_available() {
  kubectl --context "$KUBE_CONTEXT" cluster-info &>/dev/null
}

# ── Parse flags ────────────────────────────────────────────────────────────

KEEP_CLUSTER=false
for arg in "$@"; do
  case "$arg" in
    --keep-cluster) KEEP_CLUSTER=true ;;
    -h|--help)
      echo "Usage: $0 [--keep-cluster]"
      echo ""
      echo "Options:"
      echo "  --keep-cluster   Run Terraform destroy but keep the k3d cluster"
      echo "  -h, --help       Show this help"
      exit 0
      ;;
    *)
      err "Unknown option: $arg"
      exit 1
      ;;
  esac
done

# ── Pre-flight checks ─────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo "  GitOps Platform — Clean Teardown"
echo "=========================================="
echo ""

if ! command -v kubectl &>/dev/null; then
  err "kubectl not found in PATH"
  exit 1
fi

if ! command -v k3d &>/dev/null; then
  err "k3d not found in PATH"
  exit 1
fi

if ! cluster_exists; then
  warn "k3d cluster '${CLUSTER_NAME}' not found — nothing to tear down."
  # Still clean Terraform state if directory exists
  if [[ -d "$TERRAFORM_DIR" && -f "$TERRAFORM_DIR/terraform.tfstate" ]]; then
    info "Cleaning stale Terraform state..."
    cd "$TERRAFORM_DIR"
    rm -f terraform.tfstate terraform.tfstate.backup
    ok "Terraform state cleaned."
  fi
  exit 0
fi

# ── Step 1: Remove Argo CD Applications (graceful) ────────────────────────

info "Step 1/6: Removing Argo CD Application resources..."

if kube_available; then
  # Delete Application CRDs — this triggers Argo CD's finalizer controller
  # to clean up the child resources it created
  for app in infrastructure applications; do
    if kubectl --context "$KUBE_CONTEXT" -n "$ARGOCD_NS" get application "$app" &>/dev/null; then
      info "  Deleting Application '$app'..."
      kubectl --context "$KUBE_CONTEXT" -n "$ARGOCD_NS" delete application "$app" \
        --timeout="${TIMEOUT}s" 2>/dev/null || true
    fi
  done
  ok "Argo CD Applications deleted (or already gone)."
else
  warn "Cluster not reachable — skipping Application deletion."
fi

# ── Step 2: Strip finalizers from any remaining Argo CD Applications ──────

info "Step 2/6: Stripping finalizers from remaining Argo CD resources..."

if kube_available; then
  # Catch any Applications that are stuck due to finalizers
  REMAINING_APPS=$(kubectl --context "$KUBE_CONTEXT" -n "$ARGOCD_NS" \
    get applications.argoproj.io -o name 2>/dev/null || true)

  if [[ -n "$REMAINING_APPS" ]]; then
    for app in $REMAINING_APPS; do
      warn "  Removing finalizers from stuck resource: $app"
      kubectl --context "$KUBE_CONTEXT" -n "$ARGOCD_NS" patch "$app" \
        --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    done
    # Now delete them
    kubectl --context "$KUBE_CONTEXT" -n "$ARGOCD_NS" delete applications.argoproj.io --all \
      --timeout="${TIMEOUT}s" 2>/dev/null || true
  fi

  # Also strip finalizers from AppProjects if they exist
  REMAINING_PROJECTS=$(kubectl --context "$KUBE_CONTEXT" -n "$ARGOCD_NS" \
    get appprojects.argoproj.io -o name 2>/dev/null || true)

  if [[ -n "$REMAINING_PROJECTS" ]]; then
    for proj in $REMAINING_PROJECTS; do
      kubectl --context "$KUBE_CONTEXT" -n "$ARGOCD_NS" patch "$proj" \
        --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]' 2>/dev/null || true
    done
  fi

  ok "Finalizers stripped."
else
  warn "Cluster not reachable — skipping finalizer cleanup."
fi

# ── Step 3: Delete Argo CD CRDs ──────────────────────────────────────────

info "Step 3/6: Removing Argo CD CRDs..."

if kube_available; then
  ARGOCD_CRDS=$(kubectl --context "$KUBE_CONTEXT" get crds -o name 2>/dev/null \
    | grep argoproj.io || true)

  if [[ -n "$ARGOCD_CRDS" ]]; then
    for crd in $ARGOCD_CRDS; do
      info "  Deleting $crd..."
      kubectl --context "$KUBE_CONTEXT" delete "$crd" --timeout="${TIMEOUT}s" 2>/dev/null || true
    done
  fi
  ok "Argo CD CRDs removed."
else
  warn "Cluster not reachable — skipping CRD cleanup."
fi

# ── Step 4: Unstick any terminating namespaces ───────────────────────────

info "Step 4/6: Cleaning up namespaces..."

if kube_available; then
  ALL_NS=("$ARGOCD_NS" "${APP_NAMESPACES[@]}")

  for ns in "${ALL_NS[@]}"; do
    NS_STATUS=$(kubectl --context "$KUBE_CONTEXT" get namespace "$ns" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

    if [[ "$NS_STATUS" == "Terminating" ]]; then
      warn "  Namespace '$ns' is stuck Terminating — force-removing finalizers..."
      kubectl --context "$KUBE_CONTEXT" get namespace "$ns" -o json \
        | jq '.spec.finalizers = []' \
        | kubectl --context "$KUBE_CONTEXT" replace --raw "/api/v1/namespaces/${ns}/finalize" -f - \
        2>/dev/null || true
    elif [[ "$NS_STATUS" == "Active" ]]; then
      info "  Deleting namespace '$ns'..."
      kubectl --context "$KUBE_CONTEXT" delete namespace "$ns" \
        --timeout="${TIMEOUT}s" 2>/dev/null || true
    fi
  done
  ok "Namespaces cleaned up."
else
  warn "Cluster not reachable — skipping namespace cleanup."
fi

# ── Step 5: Terraform destroy ─────────────────────────────────────────────

info "Step 5/6: Running terraform destroy..."

if [[ -d "$TERRAFORM_DIR" ]]; then
  cd "$TERRAFORM_DIR"

  if [[ -f "terraform.tfstate" ]] || [[ -d ".terraform" ]]; then
    # Refresh state first (ignore errors — resources may already be gone)
    terraform refresh -input=false 2>/dev/null || true

    # Destroy with auto-approve
    if terraform destroy -auto-approve -input=false 2>/dev/null; then
      ok "Terraform destroy completed."
    else
      warn "Terraform destroy had errors (resources may already be gone)."
      # Force-clean the state since we're deleting the cluster anyway
      if [[ "$KEEP_CLUSTER" == false ]]; then
        info "  Clearing Terraform state (cluster will be deleted)..."
        rm -f terraform.tfstate terraform.tfstate.backup
      fi
    fi
  else
    info "  No Terraform state found — skipping."
  fi
else
  warn "Terraform directory not found at $TERRAFORM_DIR"
fi

# ── Step 6: Delete k3d cluster ────────────────────────────────────────────

if [[ "$KEEP_CLUSTER" == true ]]; then
  info "Step 6/6: Skipping cluster deletion (--keep-cluster flag set)."
else
  info "Step 6/6: Deleting k3d cluster '${CLUSTER_NAME}'..."

  if cluster_exists; then
    k3d cluster delete "$CLUSTER_NAME"
    ok "k3d cluster '${CLUSTER_NAME}' deleted."
  else
    warn "Cluster already gone."
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo -e "  ${GREEN}Teardown complete!${NC}"
echo "=========================================="

if [[ "$KEEP_CLUSTER" == true ]]; then
  echo ""
  echo "  Cluster is still running. To delete it later:"
  echo "    k3d cluster delete ${CLUSTER_NAME}"
fi

echo ""
