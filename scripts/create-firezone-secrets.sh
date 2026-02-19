#!/usr/bin/env bash
# Create the Firezone Phoenix/tokens Secret (SECRET_KEY_BASE, RELEASE_COOKIE, etc.).
# Run once before deploying firezone.
# Usage: ./infra/scripts/create-firezone-secrets.sh
# Requires: kubectl, openssl.

set -e

NAMESPACE="${FIREZONE_NAMESPACE:-firezone}"
SECRET_NAME="firezone-secrets"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" &>/dev/null; then
  echo "Secret $SECRET_NAME already exists in $NAMESPACE; leaving it unchanged."
  echo "To rotate: kubectl delete secret -n $NAMESPACE $SECRET_NAME, then re-run this script."
  exit 0
fi

kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-literal=SECRET_KEY_BASE="$(openssl rand -base64 48)" \
  --from-literal=LIVE_VIEW_SIGNING_SALT="$(openssl rand -base64 32)" \
  --from-literal=COOKIE_SIGNING_SALT="$(openssl rand -base64 32)" \
  --from-literal=COOKIE_ENCRYPTION_SALT="$(openssl rand -base64 32)" \
  --from-literal=TOKENS_KEY_BASE="$(openssl rand -base64 48)" \
  --from-literal=TOKENS_SALT="$(openssl rand -base64 32)" \
  --from-literal=RELEASE_COOKIE="$(openssl rand -base64 32)" \
  --from-literal=OUTBOUND_EMAIL_ADAPTER_OPTS='{}'

echo "Done. Firezone will use this Secret for Phoenix and Erlang cluster."
