# Firezone VPN (Self-Hosted) with Authentik Authentication

This guide covers deploying fully self-hosted Firezone at `firezone.tukangketik.net` and integrating it with Authentik for SSO.

## Architecture Overview

- **Firezone**: Self-hosted at `firezone.tukangketik.net` (portal) and `api.firezone.tukangketik.net` (API)
  - **Portal + API**: Helm chart in `deploy/argocd/apps/firezone/`
  - **PostgreSQL**: Bitnami chart in `deploy/argocd/apps/firezone-postgresql/`
  - **Gateway**: Helm chart in `deploy/argocd/apps/firezone-gateway/`
- **Authentik**: OIDC provider at `auth.tukangketik.net`
- **Flow**: Users sign in to Firezone → Authentik handles authentication → Firezone issues VPN access

## Prerequisites

- k3s cluster with Argo CD, Traefik, cert-manager
- Authentik running at `auth.tukangketik.net`
- DNS: `firezone.tukangketik.net` and `api.firezone.tukangketik.net` pointing to your cluster ingress

---

## Part 1: Deploy Firezone (Portal + API + Gateway)

### 1.1 Create Secrets (one-time)

Run these scripts **before** the first sync:

```bash
# PostgreSQL credentials for Firezone
./infra/scripts/create-firezone-postgresql-secret.sh

# Phoenix/Erlang secrets (SECRET_KEY_BASE, RELEASE_COOKIE, etc.)
./infra/scripts/create-firezone-secrets.sh

# Gateway token (get from Firezone portal after first account creation; see step 1.5)
# FIREZONE_TOKEN='<token>' ./infra/scripts/create-firezone-gateway-secret.sh
```

### 1.2 Apply Namespaces

```bash
kubectl apply -f infra/deploy/namespaces.yaml
```

### 1.3 Sync Argo CD Applications

Deploy in order (Argo CD sync waves handle this):

1. **firezone-postgresql** (wave 2) – PostgreSQL for Firezone
2. **firezone** (wave 3) – Portal + API
3. **firezone-gateway** (wave 3) – VPN gateway (requires token from step 1.5)

Sync via Argo CD UI or:

```bash
argocd app sync firezone-postgresql
argocd app sync firezone
# After creating account and site: argocd app sync firezone-gateway
```

### 1.4 Create First Account

Firezone does not provision an admin by default. Create an account via signup or Elixir shell:

**Option A – Signup (if enabled):** Visit `https://firezone.tukangketik.net` and sign up. Signup is enabled in values.

**Option B – Elixir shell:**

```bash
kubectl exec -it -n firezone deployment/firezone-web -- bin/firezone remote
# In the Elixir shell:
# import Portal.Accounts
# create_account("admin@tukangketik.net", "your-secure-password")
```

### 1.5 Create Site and Gateway Token

1. Log in to `https://firezone.tukangketik.net`
2. Create a **Site** (e.g. `vps-production`)
3. Go to **Deploy a Gateway** → copy the `FIREZONE_TOKEN`
4. Create the gateway secret and sync:

```bash
FIREZONE_TOKEN='<token>' ./infra/scripts/create-firezone-gateway-secret.sh
argocd app sync firezone-gateway
```

---

## Part 2: Configure Authentik OAuth2 Provider

### 2.1 Create OAuth2/OIDC Provider in Authentik

1. Log in to Authentik Admin: `https://auth.tukangketik.net/if/admin/`
2. Go to **Applications** → **Applications** → **Create with provider**
3. Select **OAuth2/OIDC** → **Next**

### 2.2 Configure OAuth2 Provider

| Setting | Value |
|---------|-------|
| **Name** | Firezone |
| **Client Type** | Confidential |
| **Redirect URIs** | `https://firezone.tukangketik.net/auth/oidc/callback` |
| **Scopes** | `openid`, `profile`, `email` |

4. Click **Submit**
5. On the **New application** page:
   - **Name**: Firezone
   - **Slug**: `firezone`
   - **Provider**: Select the Firezone provider
6. Click **Submit**

### 2.3 Get Client Credentials

1. Go to **Applications** → **Providers** → click **Firezone**
2. Note **Client ID** and **Client Secret**

### 2.4 Authentik OIDC Discovery URL

```
https://auth.tukangketik.net/application/o/firezone/.well-known/openid-configuration
```

---

## Part 3: Configure Firezone OIDC

### 3.1 Add OIDC Provider in Firezone

1. Sign in to `https://firezone.tukangketik.net`
2. Go to **Settings** → **Authentication** → **Add Provider**
3. Select **OIDC**

### 3.2 Enter OIDC Details

| Field | Value |
|-------|-------|
| **Config ID** | `authentik` |
| **Client ID** | From Authentik |
| **Client Secret** | From Authentik |
| **Discovery Document URI** | `https://auth.tukangketik.net/application/o/firezone/.well-known/openid-configuration` |
| **Redirect URI** | `https://firezone.tukangketik.net/auth/oidc/callback` |
| **Scopes** | `openid email profile` |
| **Response type** | `code` |

4. Enable **Auto-create Users** if desired
5. Save

---

## Part 4: Configure Firezone (Sites, Resources, Policies)

### 4.1 Add Resources

In your Site → **Add Resource** (e.g. `10.0.0.0/24`, internal hostnames).

### 4.2 Create Groups and Policies

1. **Groups** → create groups (e.g. `vpn-users`)
2. **Policies** → which groups can access which resources

### 4.3 Provision Users

- Add users manually, or
- Enable **Auto-create Users** in OIDC settings
- Add users to groups

---

## Part 5: Client Setup

1. Install the [Firezone Client](https://firezone.dev/kb/client-apps)
2. Sign in with your Firezone account slug (from the welcome email or admin)
3. Authenticate via Authentik (OIDC)
4. Connect to allowed resources

---

## Configuration Reference

| Component | URL |
|-----------|-----|
| Firezone Portal | `https://firezone.tukangketik.net` |
| Firezone API | `https://api.firezone.tukangketik.net` |
| OIDC Redirect URI | `https://firezone.tukangketik.net/auth/oidc/callback` |

To change the domain, edit `deploy/argocd/apps/firezone/values.yaml` (`global.externalWebURL`, `global.externalApiURL`, `global.externalApiWSURL`) and `deploy/argocd/apps/firezone-gateway/values.yaml` (`config.apiUrl`).

---

## Troubleshooting

### OIDC "You may not authenticate to this account"

- Redirect URI in Authentik must exactly match: `https://firezone.tukangketik.net/auth/oidc/callback`
- Authentik must support PKCE (default)
- Check Authentik logs for auth errors

### Gateway not connecting

- Verify `firezone-gateway-token` Secret has the correct `FIREZONE_TOKEN`
- Check logs: `kubectl logs -n firezone -l app.kubernetes.io/name=firezone-gateway -f`
- Ensure `config.apiUrl` in firezone-gateway values is `wss://api.firezone.tukangketik.net`

### Firezone pods not starting

- Ensure `firezone-postgresql` and `firezone-secrets` exist in namespace `firezone`
- PostgreSQL requires `wal_level=logical`; see [Firezone README](https://github.com/Intuinewin/helm-charts/tree/main/firezone) for migration notes

### Users can't access resources

- Confirm user is in a group with a policy for the resource
- Verify Gateway is online in the Firezone portal
- Check resource address is reachable from the Gateway

---

## Scripts

| Script | Purpose |
|--------|---------|
| `create-firezone-postgresql-secret.sh` | PostgreSQL credentials for firezone-postgresql chart |
| `create-firezone-secrets.sh` | Phoenix/Erlang secrets (SECRET_KEY_BASE, etc.) |
| `create-firezone-gateway-secret.sh` | Gateway token (from Firezone portal) |

---

## References

- [Firezone OIDC Docs](https://firezone.dev/kb/authenticate/oidc)
- [Authentik OAuth2 Provider](https://docs.goauthentik.io/add-secure-apps/providers/oauth2/)
- [Intuinewin Firezone chart](https://github.com/Intuinewin/helm-charts/tree/main/firezone)
- [Firezone FAQ](https://firezone.dev/kb/reference/faq)
