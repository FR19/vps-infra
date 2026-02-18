#!/usr/bin/env bash
# Quick diagnostic dump for Argo CD (ingress, service, pods, Traefik logs, certificate).
# Run with KUBECONFIG set. Usage: ./scripts/diagnose-argocd.sh

set -e

echo "=== Ingress ==="
kubectl get ingress -n argocd -o yaml

echo "=== Service & Endpoints ==="
kubectl get svc,ep -n argocd argocd-server

echo "=== Argo CD Server Pods ==="
kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server

echo "=== Traefik logs (last 20 lines) ==="
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=20

echo "=== Certificate ==="
kubectl get certificate -n argocd
