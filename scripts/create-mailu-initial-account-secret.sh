#!/usr/bin/env bash
# Create the Mailu initial admin account secret (admin@<domain>).
# Required when using mailu.initialAccount.existingSecret: mailu-initial-account.
# Run once, then sync the mailu app and use admin@<domain> to log in at https://mail.<host>/admin
#
# Usage: ./infra/scripts/create-mailu-initial-account-secret.sh
# Optional env:
#   MAILU_NAMESPACE   namespace (default: mailu)
#   MAILU_ADMIN_PASS  password for admin (will prompt if not set)
#
# Requires: kubectl

set -e

NAMESPACE="${MAILU_NAMESPACE:-mailu}"
SECRET_NAME="mailu-initial-account"
KEY_NAME="initial-account-password"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if [[ -z "${MAILU_ADMIN_PASS:-}" ]]; then
  echo "Enter password for Mailu admin (admin@tukangketik.net):"
  read -rs MAILU_ADMIN_PASS
  echo ""
  if [[ -z "$MAILU_ADMIN_PASS" ]]; then
    echo "Password cannot be empty."
    exit 1
  fi
fi

kubectl create secret generic "$SECRET_NAME" \
  --namespace "$NAMESPACE" \
  --from-literal="$KEY_NAME=$MAILU_ADMIN_PASS" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret $SECRET_NAME updated in $NAMESPACE."
echo "Restart the admin deployment so it picks up the account: kubectl rollout restart deployment -n $NAMESPACE -l app.kubernetes.io/component=admin"
echo "Then log in at https://mail.tukangketik.net/admin as admin@tukangketik.net"
