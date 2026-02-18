# vps-infra

Infrastructure repository for the VPS platform.

## What this repo manages
- **k3s bootstrap scripts** (harden VPS, mount data disk, install k3s)
- **cert-manager** + Let’s Encrypt issuers
- **Argo CD** (GitOps controller)
- **Authentik** (OIDC provider)

This repo intentionally **does not** deploy application services (CV/blog/frontend). Those belong in a separate services repo and can be added later as separate Argo CD Applications.

## Directory layout

```
infra/
├── vps-setup/                 # Run on VPS (disk + security + k3s)
├── deploy/
│   ├── namespaces.yaml         # Namespaces needed for infra components
│   ├── cert-manager/           # ClusterIssuers (Let’s Encrypt)
│   └── argocd/
│       ├── project.yaml        # Argo CD project allowlist
│       ├── app-of-apps.yaml    # Argo CD "infra" app-of-apps
│       ├── repo-credentials.template.yaml  # One-time repo SSH credential (manual apply)
│       └── apps/               # Argo CD Applications (source of truth)
└── docs/
    ├── deployment-infra.md
    ├── deployment.md
    ├── runbooks.md
    └── architecture.md
```

## Quickstart (infra-only)

Follow [`docs/deployment-infra.md`](docs/deployment-infra.md).

High level steps:
1. Run `vps-setup/*` scripts on the VPS (Debian 13 supported)
2. Install **cert-manager** (Helm)
3. Install **Argo CD** (Helm)
4. Create Argo CD repo access Secret (SSH deploy key)
5. Apply Argo CD `AppProject` + `app-of-apps` so Argo manages infra from YAML

## One-time: make Argo CD read a private repo (SSH deploy key)

Because this infra repo is private, Argo CD needs credentials to clone it.

Recommended approach:
- Create a **read-only Deploy Key** in GitHub repo settings
- Put the **private key** into `deploy/argocd/repo-credentials.template.yaml`
- Apply it once:

```bash
kubectl apply -f deploy/argocd/repo-credentials.template.yaml
```

Important:
- The Secret `stringData.url` must match your `Application.spec.source.repoURL` exactly (SSH URL).
- Do **not** commit a real private key to Git. Treat the template as a local edit or use a secrets solution (SOPS/SealedSecrets) later.

## Important files to edit before first sync
- `deploy/argocd/app-of-apps.yaml`: set `repoURL` (SSH URL recommended)
- `deploy/argocd/project.yaml`: allow your infra repo URL in `sourceRepos`
- `deploy/cert-manager/cluster-issuer-letsencrypt-*.yaml`: set `email:`
- `deploy/argocd/apps/authentik.application.yaml`: set `auth.<your-domain>`

## Notes
- Helm is used only to **bootstrap** Argo CD and cert-manager. After that, Argo CD becomes the reconciler and **YAML in this repo is the source of truth**.

