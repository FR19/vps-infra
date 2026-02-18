# Runbooks

This page contains operational runbooks for common tasks.

## Table of Contents

- [Emergency Procedures](#emergency-procedures)
- [Service Troubleshooting](#service-troubleshooting)
- [Backup & Restore](#backup--restore)
- [Security Incidents](#security-incidents)
- [Maintenance Tasks](#maintenance-tasks)

## Emergency Procedures

### Service Down

**Symptoms**: Services not responding, 502/503 errors

```bash
# 1. Check overall cluster health
kubectl get nodes
kubectl get pods --all-namespaces

# 2. Check ingress
kubectl get ingress --all-namespaces

# 3. Check certificates
kubectl get certificates --all-namespaces

# 4. Check resource usage
kubectl top nodes
kubectl top pods --all-namespaces

# Common fixes:
# - Restart stuck pods: kubectl delete pod -n namespace pod-name
# - Scale up: kubectl scale deployment -n namespace deployment-name --replicas=2
```

### Authentication Failure

**Symptoms**: Users cannot login, 401 errors

```bash
# 1. Check Authentik
kubectl get pods -n auth
kubectl logs -n auth deployment/authentik

# 2. Check Authentik ingress
kubectl get ingress -n auth
curl https://auth.yourdomain.com

# 3. Check JWKS endpoint
curl https://auth.yourdomain.com/application/o/vps-platform/jwks/

# 4. Verify OIDC provider configuration
# Access Authentik UI and check:
# - Provider exists
# - Applications configured
# - Client IDs match config

# Common fixes:
# - Restart Authentik: kubectl rollout restart -n auth deployment/authentik
# - Verify DNS for auth.yourdomain.com
```

### Database Issues (optional)

This infra-only setup does **not** deploy an app Postgres yet. If/when you deploy a database later, add a database runbook here for your chosen setup (Postgres, managed DB, etc.).

## Service Troubleshooting

### Adding New Services

```bash
# Use the service template
#
# Run inside the services repo (this workspace: cd ../../services)
cp -r templates/service-template-python services/your-new-service

# Customize and deploy
cd services/your-new-service
# See the services repo templates README for detailed instructions

# Create deployment
cp templates/service-template-python/deployment-template.yaml deploy/your-new-service/deployment.yaml
kubectl apply -f deploy/your-new-service/deployment.yaml
```

## Backup & Restore

For infra-only, focus backups on:
- Authentik configuration (exports, recovery codes)
- Your Git repositories (infra/services/content)

When you add an app database later, add a database backup/restore runbook here.

### Backup Secrets

```bash
# Export all secrets
kubectl get secrets --all-namespaces -o yaml > secrets-backup.yaml

# Note: Store securely, secrets are in plaintext
```

## Security Incidents

### Suspicious Activity

```bash
# 1. Check logs for failed auth
kubectl logs -n auth deployment/authentik | grep -i "failed"

# 2. Check access logs
# (example) kubectl logs -n myns deployment/myservice | grep -i POST

# 3. Block IPs using firewall (in VPS)
sudo ufw deny from SUSPICIOUS_IP to any

# 4. Review Authentik logs in UI
# - Check recent failed logins
# - Review active sessions
```

### Compromised Account

```bash
# 1. Disable account in Authentik UI
# - Find user account
# - Mark as inactive

# 2. Revoke all sessions in Authentik UI
# - User sessions tab
# - Invalidate all sessions

# 3. Rotate secrets
kubectl delete secret -n auth authentik-secret
# Create new secret with updated values

# 4. Restart affected services
# (example) kubectl rollout restart -n myns deployment/myservice
```

### Vulnerability Found

```bash
# 1. Identify affected services
kubectl get pods --all-namespaces -o wide

# 2. Check image versions
kubectl get deployment --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}'

# 3. Build updated images
# Rebuild vulnerable components with patches

# 4. Deploy updates
# Use Argo CD or kubectl apply updated deployments

# 5. Verify no vulnerable versions remain
trivy image ghcr.io/org/service:latest
```

## Maintenance Tasks

### Update k3s

```bash
# On VPS, check current version
k3s --version

# Update k3s
curl -sfL https://get.k3s.io | sh -

# Verify cluster health
kubectl get nodes
kubectl get pods --all-namespaces
```

### Rotate Certificates

```bash
# Let's Encrypt certificates auto-renew via cert-manager
# To force renewal:

# Delete the relevant Certificate resource; it will be reissued automatically.
# kubectl delete certificate -n <ns> <cert-name>
```

### Clear Old Data

Add data-cleanup procedures once you deploy app databases/services that accumulate data.

### Update Content

Content updates are pulled automatically by git-sync. To force update:

```bash
# Restart relevant service pods (example)
# kubectl delete pod -n <ns> -l app=<service>
```

### Check Disk Usage

```bash
# VPS disk usage
df -h

# Kubernetes volumes
kubectl get pvc --all-namespaces

# Check individual services (examples)
# kubectl exec -n <ns> deployment/<svc> -- df -h /content
```

## Disaster Recovery

### Corrupted etcd (k3s)

```bash
# If k3s etcd is corrupted:

# 1. Stop k3s
sudo systemctl stop k3s

# 2. Delete state
sudo rm -rf /var/lib/rancher/k3s/server/db

# 3. Restart k3s
sudo systemctl start k3s

# 4. Re-apply all manifests
# Re-run deployment process from Phase 3 onwards
```

### Full Cluster Recovery

```bash
# Restore from GitOps repo or Argo CD backup:

# 1. Recover configuration
cd deploy
kubectl apply -f namespaces.yaml
kubectl apply -f config.yaml

# 2. Restore database
# Use backup file

# 3. Redeploy services
# Argo CD will sync automatically
```