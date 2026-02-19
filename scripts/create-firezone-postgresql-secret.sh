#!/usr/bin/env bash
# Create the PostgreSQL Secret for Firezone (used by firezone-postgresql Bitnami chart).
# Run once before deploying firezone-postgresql.
# Usage: ./infra/scripts/create-firezone-postgresql-secret.sh
# Requires: kubectl, openssl.

set -e

NAMESPACE="${FIREZONE_NAMESPACE:-firezone}"
SECRET_NAME="firezone-postgresql"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" &>/dev/null; then
  echo "Secret $SECRET_NAME already exists in $NAMESPACE; leaving it unchanged."
  echo "To rotate: kubectl delete secret -n $NAMESPACE $SECRET_NAME, then re-run this script."
  exit 0
fi

PASS="$(openssl rand -base64 32)"
kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-literal=username=postgres \
  --from-literal=password="$PASS" \
  --from-literal=postgres-password="$PASS"

echo "Done. firezone-postgresql will use this Secret."
