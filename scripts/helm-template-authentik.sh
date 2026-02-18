#!/usr/bin/env bash
# Render the Authentik Helm chart locally (same as Argo CD). Use before pushing Application changes.
# Usage: ./infra/scripts/helm-template-authentik.sh [path/to/values.yaml]
# Default values: infra/deploy/argocd/apps/authentik/authentik-values.yaml (relative to repo root).
# Run from repo root. Requires: helm.

set -e

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

VALUES_FILE="${1:-infra/deploy/argocd/apps/authentik/authentik-values.yaml}"
VERSION="2024.8.1"
CHART_URL="https://github.com/goauthentik/helm/releases/download/authentik-${VERSION}/authentik-${VERSION}.tgz"

helm template authentik "$CHART_URL" \
  --namespace auth \
  -f "$VALUES_FILE"

echo "Template succeeded."
