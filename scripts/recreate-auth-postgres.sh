#!/usr/bin/env bash
# Recreate Authentik PostgreSQL so it initializes with the password from Secret
# authentik-postgresql. Use when Postgres was created without the Secret and password auth fails.
#
# WARNING: Deletes the PostgreSQL data PVC. All Authentik DB data will be lost (fresh install).
# Usage: ./infra/scripts/recreate-auth-postgres.sh
# Requires: kubectl. Optional: AUTH_NAMESPACE (default: auth).

set -e

NAMESPACE="${AUTH_NAMESPACE:-auth}"
STS_NAME="authentik-postgresql"
PVC_NAME="data-${STS_NAME}-0"

if ! kubectl get secret -n "$NAMESPACE" authentik-postgresql &>/dev/null; then
  echo "Secret authentik-postgresql not found. Create it first: ./infra/scripts/create-auth-db-secret.sh"
  exit 1
fi

echo "Scaling down PostgreSQL StatefulSet..."
kubectl scale statefulset -n "$NAMESPACE" "$STS_NAME" --replicas=0 2>/dev/null || {
  echo "StatefulSet $STS_NAME not found. Check: kubectl get statefulset -n $NAMESPACE"
  exit 1
}

echo "Waiting for pod to terminate..."
while kubectl get pods -n "$NAMESPACE" -l app.kubernetes.io/name=postgresql 2>/dev/null | grep -q .; do
  sleep 2
done

echo "Deleting PostgreSQL PVC..."
if kubectl get pvc -n "$NAMESPACE" "$PVC_NAME" &>/dev/null; then
  kubectl delete pvc -n "$NAMESPACE" "$PVC_NAME"
else
  for pvc in $(kubectl get pvc -n "$NAMESPACE" -o name 2>/dev/null | grep -i postgres || true); do
    kubectl delete -n "$NAMESPACE" "$pvc"
  done
fi

echo "Scaling PostgreSQL back to 1..."
kubectl scale statefulset -n "$NAMESPACE" "$STS_NAME" --replicas=1

kubectl wait --for=condition=ready pod -n "$NAMESPACE" -l app.kubernetes.io/name=postgresql --timeout=120s 2>/dev/null || true

echo "Restarting Authentik server and worker..."
kubectl rollout restart deployment -n "$NAMESPACE" -l app.kubernetes.io/name=authentik 2>/dev/null || true

echo "Done. Authentik will use a fresh DB with the password from Secret authentik-postgresql."
