#!/bin/bash
set -euo pipefail

# Firewall Configuration with UFW
# Run as root or with sudo

echo "=== Firewall Configuration ==="

# Install UFW if not present
if ! command -v ufw &>/dev/null; then
    echo "Installing UFW..."
    apt-get update -y
    apt-get install -y ufw
fi

# Reset firewall to default (will prompt for confirmation)
echo "Resetting UFW to default settings..."
ufw --force reset

# Set default policies
ufw default deny incoming
ufw default allow outgoing

# Allow SSH (port 22)
ufw allow 22/tcp comment 'SSH'

# Allow HTTP (port 80)
ufw allow 80/tcp comment 'HTTP'

# Allow HTTPS (port 443)
ufw allow 443/tcp comment 'HTTPS'

# Show rules
ufw show added

# Enable firewall
echo "Enabling firewall..."
ufw --force enable

# Show status
ufw status verbose

echo "=== Firewall configuration complete ==="
echo "Allowed ports: 22 (SSH), 80 (HTTP), 443 (HTTPS)"