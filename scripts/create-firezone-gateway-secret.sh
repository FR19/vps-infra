#!/usr/bin/env bash
# Create the Firezone Gateway token Secret (required for the gateway to connect to Firezone).
# Get the token from: Firezone Admin Portal -> Your Site -> Deploy Gateway -> Docker (or any tab).
# Usage: FIREZONE_TOKEN='<token>' ./infra/scripts/create-firezone-gateway-secret.sh
# Or:    ./infra/scripts/create-firezone-gateway-secret.sh   (will prompt for token)
# Requires: kubectl.

set -e

NAMESPACE="${FIREZONE_NAMESPACE:-firezone}"
SECRET_NAME="firezone-gateway-token"

if [[ -z "${FIREZONE_TOKEN:-}" ]]; then
  echo "Enter the Firezone Gateway token (from Firezone Admin -> Site -> Deploy Gateway):"
  read -rs FIREZONE_TOKEN
  echo
  if [[ -z "$FIREZONE_TOKEN" ]]; then
    echo "Error: FIREZONE_TOKEN is required." >&2
    exit 1
  fi
fi

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-literal=FIREZONE_TOKEN="$FIREZONE_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Done. firezone-gateway will use this Secret to connect to Firezone."
