#!/usr/bin/env bash
# Collect Argo CD + TLS diagnostic output so you can paste it (e.g. for 502 / secret does not exist).
# Run with KUBECONFIG set. Usage: ./infra/scripts/diagnose-argocd-tls.sh

set -e

echo "=============================================="
echo "Argo CD + TLS diagnostic dump"
echo "=============================================="
echo ""

echo "=== Certificate (argocd namespace) ==="
kubectl get certificate -n argocd 2>/dev/null || true
echo ""

echo "=== Certificate describe ==="
kubectl describe certificate -n argocd 2>/dev/null || true
echo ""

echo "=== Secret argocd-server-tls ==="
kubectl get secret -n argocd argocd-server-tls 2>/dev/null || true
echo ""

echo "=== ACME Order & Challenge (argocd namespace) ==="
kubectl get order,challenge -n argocd 2>/dev/null || true
echo ""

echo "=== Ingress (argocd namespace) ==="
kubectl get ingress -n argocd -o wide 2>/dev/null || true
echo ""

echo "=== Ingress TLS / annotations (snippet) ==="
kubectl get ingress -n argocd -o yaml 2>/dev/null | grep -A20 "tls:\|annotations:" || true
echo ""

echo "=== Service & Endpoints argocd-server ==="
kubectl get svc,ep -n argocd argocd-server 2>/dev/null || true
echo ""

echo "=== Argo CD Server Pods ==="
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server 2>/dev/null || true
echo ""

echo "=== Argo CD server deployment args ==="
kubectl get deployment argocd-server -n argocd -o yaml 2>/dev/null | grep -A5 "args:" || true
echo ""

echo "=== cert-manager logs (last 30 lines) ==="
kubectl logs -n cert-manager -l app=cert-manager --tail=30 2>/dev/null || true
echo ""

echo "=== Traefik logs (last 25 lines) ==="
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=25 2>/dev/null || true
echo ""

echo "=============================================="
echo "End of diagnostic dump"
echo "=============================================="
