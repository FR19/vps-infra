#!/bin/bash
set -euo pipefail

# Unattended Upgrades Configuration
# Run as root or with sudo

echo "=== Unattended Upgrades Configuration ==="

# Install packages
apt-get update -y
apt-get install -y unattended-upgrades apt-listchanges

# Enable unattended-upgrades using distro defaults (Debian/Ubuntu compatible)
if command -v dpkg-reconfigure >/dev/null 2>&1; then
    echo "Running dpkg-reconfigure for unattended-upgrades (noninteractive)..."
    dpkg-reconfigure -f noninteractive unattended-upgrades || true
fi

# Add local overrides without clobbering distro defaults
cat > /etc/apt/apt.conf.d/52unattended-upgrades-local << 'EOF'
// Local unattended-upgrades overrides (safe for Debian/Ubuntu)
Unattended-Upgrade::Auto-Reboot "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
EOF

# Enable automatic updates
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Verbose "0";
EOF

# Enable the service
systemctl enable unattended-upgrades
systemctl start unattended-upgrades

echo "=== Unattended upgrades configured ==="
echo "System will now install security updates automatically"