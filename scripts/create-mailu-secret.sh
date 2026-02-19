#!/usr/bin/env bash
# Create the Mailu secret and add Helm ownership metadata so the release can manage it.
# Run once before or after deploying the Mailu Application (e.g. after deleting mailu-secret).
#
# Usage: ./infra/scripts/create-mailu-secret.sh
# Optional env:
#   MAILU_NAMESPACE   namespace (default: mailu)
#   HELM_RELEASE     release name for labels (default: mailu)
#   MAILU_SECRET_KEY  optional; if set, use as secret-key instead of generating one
#
# Requires: kubectl, openssl

set -e

NAMESPACE="${MAILU_NAMESPACE:-mailu}"
RELEASE_NAME="${HELM_RELEASE:-mailu}"
SECRET_NAME="mailu-secret"

# Ensure namespace exists
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

if kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" &>/dev/null; then
  echo "Secret $SECRET_NAME already exists in $NAMESPACE; adding/updating Helm metadata only."
else
  SECRET_KEY="${MAILU_SECRET_KEY:-$(openssl rand -base64 32)}"
  kubectl create secret generic "$SECRET_NAME" \
    --namespace "$NAMESPACE" \
    --from-literal=secret-key="$SECRET_KEY"
  echo "Created secret $SECRET_NAME in $NAMESPACE with generated secret-key."
fi

# Add Helm labels/annotations so the release can own the secret
kubectl label secret "$SECRET_NAME" -n "$NAMESPACE" \
  app.kubernetes.io/managed-by=Helm --overwrite
kubectl annotate secret "$SECRET_NAME" -n "$NAMESPACE" \
  meta.helm.sh/release-name="$RELEASE_NAME" \
  meta.helm.sh/release-namespace="$NAMESPACE" \
  --overwrite

echo "Done. Secret $SECRET_NAME is ready and labeled for Helm release $RELEASE_NAME."
