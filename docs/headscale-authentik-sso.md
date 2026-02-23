# Headscale SSO with Authentik

This guide configures [Headscale](https://headscale.net/) to use [Authentik](https://goauthentik.io/) as the OIDC provider so users can log in with SSO (e.g. for the web UI or OIDC-based device registration). Paths are relative to the infra repository root.

**Prerequisites:** Authentik is deployed and reachable (e.g. `https://auth.tukangketik.net`). Headscale is deployed and its URL is known (e.g. `https://headscale.tukangketik.net`).

---

## Overview

- **Headscale** supports OIDC via config or environment variables (`HEADSCALE_OIDC_*`). The callback URL Headscale uses is **`https://<headscale-url>/oidc/callback`**. Headscale does **not** redirect the root URL (`/`) to login; you must open **`https://<headscale-url>/oidc/login`** in a browser to start the OIDC flow and get redirected to Authentik.
- **Authentik** acts as the OAuth2/OIDC provider: create an OAuth2/OpenID Provider (and optionally an Application), then use the issuer URL, client ID, and client secret in Headscale.
- Optional: use **groups** from Authentik to restrict who can use Headscale (e.g. `HEADSCALE_OIDC_ALLOWED_GROUPS`).

---

## 1. Create the OAuth2/OIDC Provider in Authentik

1. Log in to the Authentik admin UI: **https://auth.tukangketik.net** (or your Authentik host).
2. Go to **Applications** → **Providers**.
3. Click **Create** and choose **OAuth2/OpenID Provider**.
4. Fill in:
   - **Name:** `Headscale` (or e.g. `headscale`).
   - **Authorization flow:** Choose a flow that includes consent/redirect (e.g. default provider authorization flow).
   - **Application:** Leave empty for now, or create the Application first (step 2) and select it.
   - **Client type:** **Confidential**.
   - **Redirect URIs:** Add exactly:
     - `https://headscale.tukangketik.net/oidc/callback`
     - If you use a different Headscale URL, use `https://<your-headscale-host>/oidc/callback`.
   - **Signing Key:** Use an existing RS256 key or create one under **System** → **Certificates**.
5. Click **Create**.
6. After creation, open the provider and copy:
   - **Client ID**
   - **Client Secret** (show and copy; you’ll need it for Headscale).
   - **Issuer URL** (and **OpenID configuration URL** if shown).  
     The issuer is typically: `https://auth.tukangketik.net/application/o/<provider-slug>/`  
     Use this exact issuer (including trailing slash) in Headscale. The repo is preconfigured with slug `headscale`; if your provider slug differs, update `HEADSCALE_OIDC_ISSUER` in `deploy/argocd/apps/headscale/values.yaml`.

---

## 2. Create an Application in Authentik (optional but recommended)

1. Go to **Applications** → **Applications**.
2. Click **Create**.
3. Set:
   - **Name:** `Headscale`
   - **Slug:** `headscale` (used in issuer URL; keep consistent with step 1).
   - **Provider:** Select the **Headscale** OAuth2 provider you created in step 1.
   - **Launch URL:** `https://headscale.tukangketik.net` (your Headscale URL).
4. Save.

---

## 3. Configure Headscale (OIDC env vars)

Headscale is configured via environment variables. The repo already sets:

- `HEADSCALE_OIDC_ISSUER`: `https://auth.tukangketik.net/application/o/headscale/`
- `HEADSCALE_OIDC_SCOPE`: openid, profile, email, groups
- `HEADSCALE_OIDC_PKCE_ENABLED`: true
- `HEADSCALE_OIDC_PKCE_METHOD`: S256
- (OIDC `strip_email_domain` was removed in newer Headscale; omit it.)

You must set:

1. **Client ID**  
   In `deploy/argocd/apps/headscale/values.yaml`, set:
   - `HEADSCALE_OIDC_CLIENT_ID`: the Client ID from the Authentik provider.

2. **Client Secret** (do not commit)  
   Either:
   - **Option A – Secret and env patch**  
     Create a Kubernetes secret, then patch the Headscale deployment to use it (so the secret is not stored in Git or in deployment env as plain text):
     ```bash
     kubectl create secret generic headscale-oidc -n headscale --from-literal=client-secret='YOUR_CLIENT_SECRET'
     kubectl patch deployment headscale -n headscale --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"HEADSCALE_OIDC_CLIENT_SECRET","valueFrom":{"secretKeyRef":{"name":"headscale-oidc","key":"client-secret"}}}}]'
     ```
     Note: If the Helm chart already injects `HEADSCALE_OIDC_CLIENT_SECRET` as an env var (e.g. empty from values), the patch may create a duplicate. In that case, either remove the empty one from values and use only the secret, or use a different approach (e.g. Sealed Secrets / External Secrets and set the value in values).
   - **Option B – One-off env**  
     ```bash
     kubectl set env deployment/headscale HEADSCALE_OIDC_CLIENT_SECRET='YOUR_CLIENT_SECRET' -n headscale
     ```
     This is simpler but the secret may appear in `kubectl get deployment -o yaml`; prefer Option A for production.

3. **Restart Headscale** (if it was already running):
   ```bash
   kubectl rollout restart deployment/headscale -n headscale
   ```

Optional: to restrict login to certain Authentik groups, set in `values.yaml` (or via env):

- `HEADSCALE_OIDC_ALLOWED_GROUPS`: JSON array of group names, e.g. `["headscale-users"]`.
- Or use `HEADSCALE_OIDC_ALLOWED_DOMAINS` / `HEADSCALE_OIDC_ALLOWED_USERS` as per [Headscale OIDC reference](https://headscale.net/stable/ref/oidc/).

---

## 4. Verify

1. Open **`https://headscale.tukangketik.net/oidc/login`** in a browser (not the root URL — Headscale does not redirect `/` to login).
2. You should be redirected to Authentik to log in, then back to Headscale after consent.
3. The root URL `https://headscale.tukangketik.net` is the API only; for a web UI with login, use [Headplane](headplane-authentik-sso.md) at `https://headplane.tukangketik.net`.

---

## Reference

| Item | Value |
|------|--------|
| Authentik admin | `https://auth.tukangketik.net` |
| Headscale URL | `https://headscale.tukangketik.net` |
| Headscale OIDC login (start flow) | `https://headscale.tukangketik.net/oidc/login` |
| Headscale OIDC callback | `https://headscale.tukangketik.net/oidc/callback` |
| Headscale values | `deploy/argocd/apps/headscale/values.yaml` |
| Headscale OIDC ref | [headscale.net/stable/ref/oidc](https://headscale.net/stable/ref/oidc/) |
| Authentik integration | [integrations.goauthentik.io/networking/headscale](https://integrations.goauthentik.io/networking/headscale/) |

**See also:** [Headplane Authentik SSO](headplane-authentik-sso.md) — Headplane uses the same provider; add its callback URI to the Headscale provider.
