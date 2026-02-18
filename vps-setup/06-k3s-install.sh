#!/bin/bash
set -euo pipefail

# k3s Installation Script
# Run as root or with sudo

echo "=== k3s Installation ==="

# Ensure prerequisites
if ! command -v curl &>/dev/null; then
    echo "Installing curl..."
    apt-get update -y
    apt-get install -y curl
fi

# Install k3s
if [ ! -f /usr/local/bin/k3s ]; then
    echo "Installing k3s..."
    # Store k3s state on the data disk if present (recommended with /srv mounted from /dev/sdb)
    K3S_DATA_DIR="${K3S_DATA_DIR:-/srv/k3s}"
    if mountpoint -q /srv; then
        echo "Detected /srv mount. Installing k3s with --data-dir ${K3S_DATA_DIR}"
        curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--data-dir ${K3S_DATA_DIR}" sh -
    else
        echo "WARNING: /srv is not mounted. Installing k3s with default data-dir."
        echo "If you have a separate data disk, run 00-storage-sdb.sh first."
        curl -sfL https://get.k3s.io | sh -
    fi
else
    echo "k3s already installed"
fi

# Wait for k3s to be ready
echo "Waiting for k3s to be ready..."
for i in {1..30}; do
    if /usr/local/bin/k3s kubectl get nodes &>/dev/null; then
        echo "k3s is ready!"
        break
    fi
    echo "Waiting... ($i/30)"
    sleep 2
done

# Export kubeconfig for deploy user
DEPLOY_USER="deploy"
mkdir -p "/home/$DEPLOY_USER/.kube"
cp /etc/rancher/k3s/k3s.yaml "/home/$DEPLOY_USER/.kube/config"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.kube"
chmod 600 "/home/$DEPLOY_USER/.kube/config"

# Show k3s version
echo -e "\nk3s version:"
/usr/local/bin/k3s --version

# Show node status
echo -e "\nNode status:"
/usr/local/bin/k3s kubectl get nodes -o wide

echo -e "\n=== k3s installation complete ==="
echo "Kubeconfig is available at: /home/$DEPLOY_USER/.kube/config"
echo "Copy this file to your local machine at ~/.kube/config and adjust the server URL"