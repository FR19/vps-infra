#!/usr/bin/env bash
# Create the Firezone Phoenix/tokens Secret (SECRET_KEY_BASE, RELEASE_COOKIE, etc.).
# Run once before deploying firezone.
# Usage: FIREZONE_SMTP_PASSWORD='<password>' ./infra/scripts/create-firezone-secrets.sh
# Requires: kubectl, openssl.
#
# SMTP (Mailu at mail.tukangketik.net:587):
#   FIREZONE_SMTP_PASSWORD  - required for outbound email
#   FIREZONE_SMTP_RELAY     - default: mail.tukangketik.net
#   FIREZONE_SMTP_PORT      - default: 587
#   FIREZONE_SMTP_USERNAME  - default: firezone@tukangketik.net

set -e

NAMESPACE="${FIREZONE_NAMESPACE:-firezone}"
SECRET_NAME="firezone-secrets"

SMTP_RELAY="${FIREZONE_SMTP_RELAY:-mail.tukangketik.net}"
SMTP_PORT="${FIREZONE_SMTP_PORT:-587}"
SMTP_USERNAME="${FIREZONE_SMTP_USERNAME:-firezone@tukangketik.net}"
SMTP_PASSWORD="${FIREZONE_SMTP_PASSWORD:-}"

kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if kubectl get secret -n "$NAMESPACE" "$SECRET_NAME" &>/dev/null; then
  echo "Secret $SECRET_NAME already exists in $NAMESPACE; leaving it unchanged."
  echo "To rotate: kubectl delete secret -n $NAMESPACE $SECRET_NAME, then re-run this script."
  exit 0
fi

# Build OUTBOUND_EMAIL_ADAPTER_OPTS for Swoosh SMTP (Mailu STARTTLS on 587)
if [[ -n "$SMTP_PASSWORD" ]]; then
  if command -v jq &>/dev/null; then
    EMAIL_OPTS=$(jq -n \
      --arg relay "$SMTP_RELAY" \
      --argjson port "$SMTP_PORT" \
      --arg user "$SMTP_USERNAME" \
      --arg pass "$SMTP_PASSWORD" \
      '{relay:$relay,port:$port,username:$user,password:$pass,tls:"always",auth:"always"}')
  else
    # Fallback: printf may break if password contains " or \
    EMAIL_OPTS=$(printf '{"relay":"%s","port":%s,"username":"%s","password":"%s","tls":"always","auth":"always"}' \
      "$SMTP_RELAY" "$SMTP_PORT" "$SMTP_USERNAME" "$SMTP_PASSWORD")
  fi
else
  echo "Warning: FIREZONE_SMTP_PASSWORD not set. Using empty SMTP opts; email sending may fail."
  EMAIL_OPTS='{}'
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
  --from-literal=OUTBOUND_EMAIL_ADAPTER_OPTS="$EMAIL_OPTS"

echo "Done. Firezone will use this Secret for Phoenix and Erlang cluster."
