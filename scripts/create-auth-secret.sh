#!/usr/bin/env bash
# Create the Authentik secret_key Secret (required for Authentik to start).
# Run once before or after deploying the Authentik Application.
# Usage: ./infra/scripts/create-auth-secret.sh
# Requires: kubectl, openssl. Optional: AUTH_NAMESPACE (default: auth).

set -e

NAMESPACE="${AUTH_NAMESPACE:-auth}"
SECRET_NAME="authentik-secret-key"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-literal=secret_key="$(openssl rand -base64 48)" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Done. Authentik server/worker will use AUTHENTIK_SECRET_KEY from this Secret."
