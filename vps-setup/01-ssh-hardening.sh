#!/bin/bash
set -euo pipefail

# VPS SSH Hardening Script
# Run as root or with sudo

echo "=== SSH Hardening ==="

# Create deploy user
DEPLOY_USER="deploy"
if ! id "$DEPLOY_USER" &>/dev/null; then
    echo "Creating deploy user..."
    useradd -m -s /bin/bash "$DEPLOY_USER"
    usermod -aG sudo "$DEPLOY_USER"
    echo "User $DEPLOY_USER created. Please add SSH keys to /home/$DEPLOY_USER/.ssh/authorized_keys"
else
    echo "User $DEPLOY_USER already exists"
fi

# Ensure .ssh directory exists
mkdir -p "/home/$DEPLOY_USER/.ssh"
chown -R "$DEPLOY_USER:$DEPLOY_USER" "/home/$DEPLOY_USER/.ssh"
chmod 700 "/home/$DEPLOY_USER/.ssh"
chmod 600 "/home/$DEPLOY_USER/.ssh/authorized_keys" 2>/dev/null || true

# SSH hardening
SSH_CONFIG="/etc/ssh/sshd_config"
SSHD_CONFIG_BACKUP="/etc/ssh/sshd_config.backup.$(date +%Y%m%d)"

if ! diff "$SSH_CONFIG" "$SSHD_CONFIG_BACKUP" &>/dev/null; then
    cp "$SSH_CONFIG" "$SSHD_CONFIG_BACKUP"
    echo "Backup created: $SSHD_CONFIG_BACKUP"
fi

echo "Applying SSH hardening settings..."

# Disable password authentication
sed -i 's/^#*PasswordAuthentication yes/PasswordAuthentication no/' "$SSH_CONFIG"
sed -i 's/^#*PasswordAuthentication no/PasswordAuthentication no/' "$SSH_CONFIG"

# Disable root login
sed -i 's/^#*PermitRootLogin yes/PermitRootLogin no/' "$SSH_CONFIG"
sed -i 's/^#*PermitRootLogin prohibit-password/PermitRootLogin no/' "$SSH_CONFIG"

# Keep PAM enabled (recommended on Debian/systemd setups)
sed -i 's/^#*UsePAM no/UsePAM yes/' "$SSH_CONFIG"
sed -i 's/^#*UsePAM yes/UsePAM yes/' "$SSH_CONFIG"

# Only allow key authentication
sed -i 's/^#*PubkeyAuthentication no/PubkeyAuthentication yes/' "$SSH_CONFIG"

# Test SSH configuration
echo "Testing SSH configuration..."
sshd -t

# Reload SSH (Debian uses ssh.service; some distros use sshd.service)
if systemctl list-unit-files | grep -q '^ssh\.service'; then
    systemctl reload ssh || systemctl restart ssh
else
    systemctl reload sshd || systemctl restart sshd
fi

echo "=== SSH hardening complete ==="
echo "IMPORTANT: Ensure you have added your SSH public key to /home/$DEPLOY_USER/.ssh/authorized_keys before logging out!"