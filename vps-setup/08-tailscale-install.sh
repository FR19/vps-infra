#!/bin/bash
set -euo pipefail

# Install Tailscale client on the VPS host (for Headscale VPN).
# After this, run tailscale up with your Headscale URL and pre-auth key (see docs/vpn-headscale.md).

echo "=== Tailscale client install (Headscale) ==="

if command -v tailscale &>/dev/null; then
    echo "Tailscale is already installed: $(tailscale --version 2>/dev/null || true)"
    exit 0
fi

# Add Tailscale repo (Debian/Ubuntu)
if [[ -f /etc/debian_version ]]; then
    curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
    curl -fsSL https://pkgs.tailscale.com/stable/debian/trixie.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list
    apt-get update -y
    apt-get install -y tailscale
else
    echo "Unsupported OS: only Debian/Ubuntu supported. Install Tailscale manually: https://tailscale.com/download/linux"
    exit 1
fi

echo "Tailscale installed. Enable and connect with:"
echo "  sudo tailscale up --login-server=https://headscale.tukangketik.net --accept-dns=false --authkey=YOUR_PREAUTH_KEY --hostname=vps"
echo "See docs/vpn-headscale.md for pre-auth key creation and full steps."
