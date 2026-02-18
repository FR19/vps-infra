#!/usr/bin/env bash
# Create the PostgreSQL password Secret for Authentik's Bitnami PostgreSQL subchart.
# Run once (or re-run to ensure it exists). Re-run does not overwrite existing Secret.
# Usage: ./infra/scripts/create-auth-db-secret.sh
# Requires: kubectl, openssl. Optional: AUTH_NAMESPACE (default: auth).

set -e

NAMESPACE="${AUTH_NAMESPACE:-auth}"
SECRET_NAME="authentik-postgresql"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" &>/dev/null; then
  echo "Secret $SECRET_NAME already exists in $NAMESPACE; leaving it unchanged."
  echo "To rotate: kubectl delete secret -n $NAMESPACE $SECRET_NAME, then re-run this script."
  exit 0
fi

PASS="$(openssl rand -base64 32)"
kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-literal=password="$PASS" \
  --from-literal=postgres-password="$PASS"

echo "Done."
