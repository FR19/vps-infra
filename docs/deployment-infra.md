# Infrastructure deployment guide

This guide deploys the base platform infrastructure on a K3s cluster: **cert-manager** (Let's Encrypt), **Argo CD** (GitOps), and **Authentik** (identity provider). All paths are relative to the **infra repository root**.

---

## Prerequisites

- `kubectl` configured for your k3s cluster
- `helm` (v3)
- `openssl` and `envsubst` (e.g. `gettext-base` on Debian)

Verify:

```bash
kubectl get nodes
helm list -A
# If Helm doesn't see the cluster: use --kubeconfig="$KUBECONFIG" where needed
```

---

## Pre-deployment checklist

Before running the deployment steps, configure the following (one-time):

| Item                     | Location                                                                           |
| ------------------------ | ---------------------------------------------------------------------------------- |
| Infra repo URL           | `deploy/argocd/app-of-apps.yaml` — `spec.source.repoURL`                           |
| Project source repos     | `deploy/argocd/project.yaml` — `spec.sourceRepos`                                  |
| Argo CD hostname         | `deploy/argocd/helm/values.yaml` — `server.ingress.hostname`                       |
| Authentik hostname       | `deploy/argocd/apps/authentik/authentik.application.yaml` — `server.ingress.hosts` |
| Let's Encrypt email      | `deploy/cert-manager/cluster-issuer-letsencrypt-*.yaml` — `email:`                 |
| Argo CD repo credentials | Create Secret from `deploy/argocd/repo-credentials.template.yaml`                  |

Ensure DNS for the Argo CD hostname (e.g. `argocd.example.com`) points to the VPS before installing Argo CD.

---

## 1) VPS bootstrap (on the VPS)

Run from your VPS bootstrap directory (e.g. `vps-setup/` if present in the repo):

```bash
cd vps-setup

# Optional: use a dedicated data disk
sudo CONFIRM_ERASE_SDB=yes bash 00-storage-sdb.sh

sudo bash 01-ssh-hardening.sh
sudo bash 02-firewall.sh
sudo bash 03-unattended-upgrades.sh
sudo bash 04-fail2ban.sh
sudo bash 05-time-sync.sh
sudo bash 06-k3s-install.sh
sudo bash 07-k3s-local-path-to-srv.sh
```

## 2) Connect kubectl (SSH tunnel recommended)

Do not expose the Kubernetes API (6443) publicly. Use an SSH tunnel from your local machine:

```bash
ssh -L 6443:127.0.0.1:6443 deploy@YOUR_VPS_IP
```

In kubeconfig, use `server: https://127.0.0.1:6443`. Verify with `kubectl get nodes`.

If Helm does not use your kubeconfig (e.g. in scripts or IDEs), pass it explicitly: `--kubeconfig="${KUBECONFIG:-$HOME/.kube/config}"` or set `HELM_OPTS="--kubeconfig=$KUBECONFIG"` and use `helm $HELM_OPTS ...` for all Helm commands.

## 3) Create namespaces

```bash
kubectl apply -f deploy/namespaces.yaml
```

## 4) Set domain variable

```bash
export DOMAIN_NAME="yourdomain.com"
```

## 5) Install cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update

helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager \
  --create-namespace \
  --set crds.enabled=true
```

Apply Let's Encrypt issuers:

```bash
kubectl apply -f deploy/cert-manager/cluster-issuer-letsencrypt-staging.yaml
kubectl apply -f deploy/cert-manager/cluster-issuer-letsencrypt-prod.yaml
```

## 6) Install Argo CD

The Argo CD hostname is defined in `deploy/argocd/helm/values.yaml` (`server.ingress.hostname`). Ensure DNS for that hostname points to the VPS.

From the **infra repo root**:

```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm dependency update deploy/argocd/helm

helm upgrade --install argocd deploy/argocd/helm \
  --namespace argocd \
  --create-namespace \
  -f deploy/argocd/helm/values.yaml
```

The bundled values configure TLS (cert-manager), Traefik ingress, `--insecure` for the server, and RBAC. After step 7, Argo CD will manage itself from Git using this same chart.

## 7) Enable GitOps (project and app-of-apps)

Apply the Argo CD project and the app-of-apps so Argo CD manages all infra from the repo.

**Layout:** Each app lives in its own directory under `deploy/argocd/apps/` (e.g. `argocd/`, `authentik/`). The top-level `kustomization.yaml` includes all Application manifests. To add a new app, create a subdirectory and add its manifest to `kustomization.yaml`.

```bash
kubectl apply -f deploy/argocd/project.yaml

# One-time: create repo credential Secret (edit the template first)
kubectl apply -f deploy/argocd/repo-credentials.template.yaml

kubectl apply -f deploy/argocd/app-of-apps.yaml

# One-time: Authentik requires these Secrets before it can start
./scripts/create-auth-secret.sh
./scripts/create-auth-db-secret.sh
```

Retrieve the initial admin password and log in:

```bash
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
echo
# Open https://argocd.${DOMAIN_NAME} and log in as admin
```

After the **argocd** Application syncs, Argo CD manages itself from the repo and RBAC allows admin access to apps in the `vps-platform` project.

---

## Operations (reference)

### Update Argo CD config in place

To apply changes from `deploy/argocd/helm/values.yaml` without reinstalling:

```bash
helm dependency update deploy/argocd/helm
helm upgrade --install argocd deploy/argocd/helm \
  --namespace argocd \
  -f deploy/argocd/helm/values.yaml
kubectl -n argocd rollout restart deployment argocd-server
```

If the **argocd** Application has auto-sync enabled, it will reconcile from Git; ensure the repo contains the desired values so sync does not overwrite local changes.

### Test Application manifests locally

To avoid manifest errors in Argo CD after editing Helm values, render the chart locally first.

**Authentik:**

```bash
./scripts/helm-template-authentik.sh
```

Uses `deploy/argocd/apps/authentik/authentik-values.yaml`. Keep that file in sync with the `values` block in `authentik.application.yaml`. Optional: `./scripts/helm-template-authentik.sh path/to/other-values.yaml`.

**Other Helm-based apps:** Run `helm template <releaseName> <chart> --namespace <ns> -f <values-file>` with the same chart version and values as the Application.

### Teardown options

- **Full infra teardown:** See [Teardown (full)](#teardown-full).
- **Argo CD only:** See [Teardown only Argo CD](#teardown-only-argocd).

---

## Teardown (full)

Use when re-deploying infra from scratch. From the infra repo root (with `KUBECONFIG` set):

**Script (recommended):**

```bash
./scripts/cleanup-infra.sh
# Or: ./scripts/cleanup-infra.sh --yes
```

**Manual:**

```bash
kubectl patch application -n argocd infra-app-of-apps -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl delete application -n argocd --all --timeout=60s 2>/dev/null || true
helm uninstall argocd -n argocd 2>/dev/null || true
helm uninstall authentik -n auth 2>/dev/null || true
helm uninstall cert-manager -n cert-manager 2>/dev/null || true
kubectl delete namespace argocd auth cert-manager --timeout=120s --ignore-not-found=true
```

Then start again from **1) VPS bootstrap** (or from **3) Create namespaces** if the VPS and k3s are already in place).

---

## Teardown only Argo CD

Use when only Argo CD needs to be reinstalled; cert-manager and Authentik are left in place.

```bash
kubectl patch application -n argocd infra-app-of-apps -p '{"metadata":{"finalizers":null}}' --type=merge 2>/dev/null || true
kubectl delete application -n argocd --all --timeout=60s 2>/dev/null || true
helm uninstall argocd -n argocd 2>/dev/null || true
```

Then run **6) Install Argo CD** and **7) Enable GitOps** again (apply `project.yaml`, repo credentials, and `app-of-apps.yaml`).

---

## Troubleshooting

| Issue                                                              | See                                                                                                      |
| ------------------------------------------------------------------ | -------------------------------------------------------------------------------------------------------- |
| Argo CD 404 by domain, TLS/502, backend port, certificate warnings | [Runbooks: Argo CD](runbooks.md#argocd) — 404 and 502/TLS sections                                       |
| Helm upgrade not applying / Argo CD overwriting Helm               | [Runbooks: Argo CD](runbooks.md#argocd) — Ingress backend port, Git as source of truth                   |
| Authentik: secret key missing, Postgres auth failed, unhealthy     | [Runbooks: Authentik](runbooks.md#authentik)                                                             |
| Authentik: OutOfSync (StatefulSet creationTimestamp)               | [Runbooks: Authentik — Cosmetic OutOfSync](runbooks.md#cosmetic-outofsync-statefulset-creationtimestamp) |
| Argo CD RBAC permission denied                                     | [Runbooks: Argo CD — RBAC](runbooks.md#rbac--permission-denied-for-app)                                  |

For a full list of procedures: [Runbooks](runbooks.md).

---

## What's next

- **Mailu (mail server):** To install the Mailu stack (webmail, SMTP, IMAP) managed by Argo CD, follow **[mailu-install.md](mailu-install.md)**. It covers domain configuration, creating the required secrets, syncing the mailu Application, and first login.
- **Argo CD SSO:** To log in to Argo CD via Authentik (OIDC SSO), follow **[authentik-argocd-sso.md](authentik-argocd-sso.md)**.
- **VPN-only Argo CD (Headscale):** To make Argo CD reachable only over VPN and enroll devices, follow **[vpn-headscale.md](vpn-headscale.md)**.
- **VPN-only internal apps:** To add new VPN-only hostnames behind `incluster-vpn`, follow **[vpn-only-apps.md](vpn-only-apps.md)**.
- Deploy application services (CV, blog, frontend) by adding manifests under `deploy/` or a separate repo and registering a dedicated Argo CD Application.
