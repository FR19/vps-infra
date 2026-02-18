# VPS Setup Scripts

This directory contains scripts to harden and configure your VPS for the microservices platform.

## Prerequisites

- Fresh VPS with Debian 13 (or Ubuntu 22.04/24.04)
- Root access or sudo privileges
- Your SSH public key ready

## Setup Order

Run these scripts in order on your VPS:

### 0. Storage setup (recommended)
If you have a second disk (e.g. `/dev/sdb`) for data, use it for k3s state + persistent volumes.

This will **ERASE `/dev/sdb`** and mount it to `/srv`.

```bash
cd /path/to/vps-setup
sudo CONFIRM_ERASE_SDB=yes bash 00-storage-sdb.sh
```

### 1. SSH Hardening
```bash
cd /path/to/vps-setup
sudo bash 01-ssh-hardening.sh
```

**IMPORTANT:** Before running this, add your SSH public key to `/home/deploy/.ssh/authorized_keys` manually or the script will guide you.

### 2. Firewall Configuration
```bash
sudo bash 02-firewall.sh
```

This enables UFW with only ports 22, 80, and 443 open.

### 3. Unattended Upgrades
```bash
sudo bash 03-unattended-upgrades.sh
```

This enables automatic security updates.

### 4. Fail2ban
```bash
sudo bash 04-fail2ban.sh
```

This protects against brute force attacks.

### 5. Time Sync
```bash
sudo bash 05-time-sync.sh
```

This ensures accurate time on your VPS.

### 6. k3s Installation
```bash
sudo bash 06-k3s-install.sh
```

This installs k3s (lightweight Kubernetes).

### 7. Move k3s PV storage to `/srv` (recommended)
This makes the default `local-path` StorageClass provision PVs under `/srv/k3s/storage`.

```bash
sudo bash 07-k3s-local-path-to-srv.sh
```

## Accessing k3s from Your Local Machine

After installing k3s, copy the kubeconfig from the VPS to your local machine:

```bash
# On VPS
cat /home/deploy/.kube/config

# On your local machine, save to ~/.kube/config-vps
# Then either:
# 1. Use it directly: KUBECONFIG=~/.kube/config-vps kubectl get nodes
# 2. Or merge it and change server URL to your VPS IP
```

**Important:** Change the `server` URL in the kubeconfig from `https://127.0.0.1:6443` to `https://YOUR_VPS_IP:6443`.

## Verify k3s Installation

```bash
# Check nodes
kubectl get nodes

# Check storage class
kubectl get storageclass

# Check Traefik ingress
kubectl get pods -n kube-system | grep traefik
```

## Next Steps

After completing these scripts, continue with:
- Installing cert-manager (Phase 3)
- Installing Argo CD (Phase 4)
- Installing Authentik (Phase 5)