#!/bin/bash
set -euo pipefail

# Fail2ban Configuration for SSH
# Run as root or with sudo

echo "=== Fail2ban Configuration ==="

# Install fail2ban
apt-get update -y
apt-get install -y fail2ban

# Create fail2ban configuration
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 5
destemail = root@localhost
sender = fail2ban@localhost
action = %(action_mwl)s

[sshd]
enabled = true
port = 22
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
EOF

# Start and enable fail2ban
systemctl enable fail2ban
systemctl start fail2ban

# Check status
fail2ban-client status
fail2ban-client status sshd

echo "=== Fail2ban configured and running ==="
echo "SSH will be banned after 3 failed attempts for 1 hour"