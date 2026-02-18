#!/usr/bin/env bash
# Cleanup all infra (Argo CD, Authentik, cert-manager) so you can deploy from scratch.
# Run from your local machine with KUBECONFIG set to your k3s cluster.
# Usage: ./scripts/cleanup-infra.sh [--yes]

set -e

YES=
if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]]; then
  YES=1
fi

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[1;33m'
nc='\033[0m'

info()  { echo -e "${green}[INFO]${nc} $*"; }
warn()  { echo -e "${yellow}[WARN]${nc} $*"; }
err()   { echo -e "${red}[ERR]${nc} $*"; }

# Pre-checks
if ! command -v kubectl &>/dev/null; then
  err "kubectl not found. Install it and retry."
  exit 1
fi

if ! command -v helm &>/dev/null; then
  err "helm not found. Install it and retry."
  exit 1
fi

if ! kubectl cluster-info &>/dev/null; then
  err "Cannot reach cluster. Set KUBECONFIG and retry."
  exit 1
fi

echo "This will remove:"
echo "  - All Argo CD Applications (incl. app-of-apps)"
echo "  - Helm release: argocd (namespace argocd)"
echo "  - Helm release: authentik (namespace auth)"
echo "  - Helm release: cert-manager (namespace cert-manager)"
echo "  - Namespaces: argocd, auth, cert-manager"
echo ""
echo "k3s and the VPS are not touched. You can re-run deployment from step 3 (Create namespaces)."
echo ""

if [[ -z "$YES" ]]; then
  read -p "Continue? [y/N] " -n 1 -r
  echo
  if [[ ! "$REPLY" =~ ^[yY]$ ]]; then
    info "Aborted."
    exit 0
  fi
fi

info "1/5 Removing app-of-apps finalizer..."
kubectl patch application -n argocd infra-app-of-apps -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true

info "2/5 Deleting all Argo CD Applications..."
kubectl delete application -n argocd --all --timeout=60s 2>/dev/null || true

info "3/5 Uninstalling Helm releases..."
helm uninstall argocd -n argocd 2>/dev/null || true
helm uninstall authentik -n auth 2>/dev/null || true
helm uninstall cert-manager -n cert-manager 2>/dev/null || true

info "4/5 Deleting namespaces (argocd, auth, cert-manager)..."
kubectl delete namespace argocd auth cert-manager --timeout=120s --ignore-not-found=true

info "5/5 Waiting for namespaces to be gone..."
for ns in argocd auth cert-manager; do
  if kubectl get namespace "$ns" &>/dev/null; then
    warn "Namespace $ns still exists, waiting..."
    kubectl wait --for=delete "namespace/$ns" --timeout=120s 2>/dev/null || true
  fi
done

echo ""
info "Cleanup done. Verifying..."
echo ""
kubectl get ns 2>/dev/null || true
echo ""
if kubectl get pods -A 2>/dev/null | grep -E 'argocd|cert-manager|auth' || true; then
  warn "Some pods may still be terminating. Wait a moment and run: kubectl get pods -A"
else
  info "No argocd/cert-manager/auth pods found."
fi

echo ""
info "Next: follow deployment-infra.md from step 3 (Create namespaces) or from step 1 if you also re-bootstrap the VPS."
