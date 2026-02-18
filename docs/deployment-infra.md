# Infra-only deployment (cert-manager + Argo CD + Authentik) — YAML is source of truth

This guide deploys **only**:
- cert-manager (+ Let’s Encrypt issuers)
- Argo CD
- Authentik

It intentionally **does not deploy**:
- CV service
- Blog service
- Frontend

## Prerequisites (local machine)
- `kubectl` configured to reach your k3s cluster
- `helm` installed
- `openssl` installed
- `envsubst` installed (`gettext-base` on Debian)

## 1) VPS bootstrap (on the VPS)
From the infra repo:

```bash
cd infra/vps-setup

# Optional but recommended if you have /dev/sdb as a data disk
sudo CONFIRM_ERASE_SDB=yes bash 00-storage-sdb.sh

sudo bash 01-ssh-hardening.sh
sudo bash 02-firewall.sh
sudo bash 03-unattended-upgrades.sh
sudo bash 04-fail2ban.sh
sudo bash 05-time-sync.sh
sudo bash 06-k3s-install.sh
sudo bash 07-k3s-local-path-to-srv.sh
```

## 2) Connect `kubectl` safely (recommended: SSH tunnel)
Do **not** open port 6443 publicly. Use an SSH tunnel from your local machine:

```bash
ssh -L 6443:127.0.0.1:6443 deploy@YOUR_VPS_IP
```

In your local kubeconfig, keep:

```yaml
server: https://127.0.0.1:6443
```

Verify:

```bash
kubectl get nodes
```

## 3) Create namespaces

```bash
kubectl apply -f infra/deploy/namespaces.yaml
```

## 4) Set variables used by infra components

Set required env vars:

```bash
export DOMAIN_NAME="yourdomain.com"
```

Notes:
- We are **not** deploying any app services in the infra-only phase. Add app components later when you’re ready.
- Authentik will use its own Postgres/Redis subcharts in this infra-only guide.

Before continuing, edit these YAMLs in the infra repo (source of truth):
- `infra/deploy/argocd/app-of-apps.yaml` (set `repoURL` to your infra repo)
- `infra/deploy/argocd/project.yaml` (set `sourceRepos` for your infra repo URL)
- `infra/deploy/argocd/apps/authentik.application.yaml` (set `auth.<domain>`)
- `infra/deploy/cert-manager/cluster-issuer-letsencrypt-*.yaml` (set `email:`)
- Create an Argo CD repo credential Secret (manual, one-time): `infra/deploy/argocd/repo-credentials.template.yaml`

## 5) Install cert-manager (Helm)

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

Create Let’s Encrypt issuers:

```bash
kubectl apply -f infra/deploy/cert-manager/cluster-issuer-letsencrypt-staging.yaml
kubectl apply -f infra/deploy/cert-manager/cluster-issuer-letsencrypt-prod.yaml
```

## 6) Install Argo CD (Helm)

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --create-namespace \
  --set server.ingress.enabled=true \
  --set server.ingress.annotations."traefik\.ingress\.kubernetes\.io/router\.entrypoints"=websecure \
  --set server.ingress.annotations."cert-manager\.io/cluster-issuer"=letsencrypt-prod \
  --set server.ingress.hostname="argocd.${DOMAIN_NAME}" \
  --set server.ingress.tls=true
```

## 7) Enable GitOps for infra (Argo CD manages infra from YAML)

Now that Argo CD is installed, apply the Argo CD **project** + **infra app-of-apps** from this repo.

This will make Argo CD install/manage (from YAML in `deploy/argocd/apps/`):
- cert-manager (Helm)
- cert-manager issuers (manifests)
- Authentik (Helm)

```bash
kubectl apply -f infra/deploy/argocd/project.yaml

# One-time: create a repo credential Secret in argocd namespace (for private infra repo)
# Edit infra/deploy/argocd/repo-credentials.template.yaml first.
kubectl apply -f infra/deploy/argocd/repo-credentials.template.yaml

kubectl apply -f infra/deploy/argocd/app-of-apps.yaml
```

Get the initial Argo CD admin password:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo
```

## What’s next
- When you're ready to deploy CV/blog/frontend later, re-add the service manifests into `infra/deploy/` (or create a separate services infra repo) and create a dedicated Argo CD `Application` for them.

