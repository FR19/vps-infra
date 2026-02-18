#!/bin/bash
set -euo pipefail

# Time Sync Configuration with systemd-timesyncd
# Run as root or with sudo

echo "=== Time Sync Configuration ==="

# Ensure systemd-timesyncd is installed and running
if command -v timedatectl &>/dev/null; then
    echo "Configuring systemd-timesyncd..."

    # Enable systemd-timesyncd
    systemctl enable systemd-timesyncd
    systemctl start systemd-timesyncd

    # Enable NTP sync and set time zone (you may need to adjust timezone)
    timedatectl set-ntp true

    # Show status
    echo "Time sync status:"
    timedatectl status

    # Show systemd-timesyncd status
    echo -e "\nSystemd-timesyncd status:"
    systemctl status systemd-timesyncd --no-pager
else
    echo "systemd-timesyncd not found, installing chrony..."
    apt-get update -y
    apt-get install -y chrony

    # Start and enable chrony
    systemctl enable chrony
    systemctl start chrony

    # Show status
    chrony tracking
fi

echo "=== Time sync configured ==="