#!/bin/bash
set -euo pipefail

# Configure k3s local-path-provisioner to place PVs under /srv/k3s/storage
# This should be run AFTER k3s installation.

K3S_STORAGE_DIR="${K3S_STORAGE_DIR:-/srv/k3s/storage}"

if [[ "${EUID}" -ne 0 ]]; then
  echo "ERROR: Please run as root (sudo)."
  exit 1
fi

if ! mountpoint -q /srv; then
  echo "ERROR: /srv is not mounted. Run 00-storage-sdb.sh first."
  exit 1
fi

if [[ ! -d "${K3S_STORAGE_DIR}" ]]; then
  echo "Creating ${K3S_STORAGE_DIR}..."
  mkdir -p "${K3S_STORAGE_DIR}"
fi

if [[ ! -x /usr/local/bin/k3s ]]; then
  echo "ERROR: k3s not found at /usr/local/bin/k3s. Install k3s first (06-k3s-install.sh)."
  exit 1
fi

echo "=== Configuring local-path-provisioner to use ${K3S_STORAGE_DIR} ==="

# The local-path-provisioner reads this ConfigMap:
# kube-system/local-path-config data.config.json with nodePathMap paths.

cat <<EOF | /usr/local/bin/k3s kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-path-config
  namespace: kube-system
data:
  config.json: |
    {
      "nodePathMap":[
        {
          "node":"DEFAULT_PATH_FOR_NON_LISTED_NODES",
          "paths":["${K3S_STORAGE_DIR}"]
        }
      ]
    }
EOF

echo "Restarting local-path-provisioner to pick up changes..."
/usr/local/bin/k3s kubectl -n kube-system rollout restart deployment/local-path-provisioner || true

echo "Done."
echo "New PVCs using StorageClass 'local-path' will be provisioned under: ${K3S_STORAGE_DIR}"
echo "Note: Existing PVs (if any) are NOT migrated by this script."

