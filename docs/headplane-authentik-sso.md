# Headplane SSO with Authentik

[Headplane](https://headplane.net) is the web UI for Headscale. This guide configures Headplane to use **the same** Authentik OAuth2/OIDC provider as Headscale so user identities stay in sync. Paths are relative to the **infra repository root**.

**Prerequisites:** Headscale is already using Authentik ([headscale-authentik-sso.md](headscale-authentik-sso.md)). Headplane is deployed.

---

## 1. Add Headplane redirect URI in Authentik

1. In Authentik: **Applications** → **Providers** → open the **Headscale** OAuth2/OpenID provider.
2. Under **Redirect URIs**, add:
   - `https://headplane.tukangketik.net/admin/oidc/callback`
3. Save.

You do **not** create a new provider; Headplane uses the same client ID and client secret as Headscale.

---

## 2. Set Headplane config and secrets

**Client ID (must match Headscale):**

- In `deploy/argocd/apps/headplane/manifests/headplane-configmap.yaml`, set `oidc.client_id` to the same value as `HEADSCALE_OIDC_CLIENT_ID` in `deploy/argocd/apps/headscale/values.yaml`.
- Or after deploy: `kubectl edit configmap headplane-config -n headplane` and set `oidc.client_id` to that value.

**Secrets (not in Git — create manually before or after first sync):**

The `headplane-secrets` Secret is not applied from the repo; create it once in the cluster:

1. **Create the secret** with cookie secret (32 chars), OIDC client secret (same as Headscale), and Headscale API key:

   ```bash
   kubectl exec -n headscale deploy/headscale -- headscale apikeys create --expiration 999d
   # Then create the secret (paste the API key and your Authentik client secret):
   kubectl create secret generic headplane-secrets -n headplane \
     --from-literal=cookie_secret=$(openssl rand -base64 24 | head -c 32) \
     --from-literal=oidc_client_secret='YOUR_AUTHENTIK_CLIENT_SECRET' \
     --from-literal=headscale_api_key='PASTE_HEADSCALE_API_KEY_ABOVE'
   ```

2. **Restart Headplane** (if already deployed):

   ```bash
   kubectl rollout restart deployment/headplane -n headplane
   ```

---

## 3. Verify

1. Open `https://headplane.tukangketik.net` (or `https://headplane.tukangketik.net/admin`).
2. You should be offered OIDC login; choose it and sign in with Authentik.
3. After consent, you should land in the Headplane UI.

---

## Reference

| Item | Value |
|------|--------|
| Headplane URL | `https://headplane.tukangketik.net` |
| OIDC callback | `https://headplane.tukangketik.net/admin/oidc/callback` |
| Provider | Same as Headscale (issuer `https://auth.tukangketik.net/application/o/headscale/`) |
| ConfigMap | `deploy/argocd/apps/headplane/manifests/headplane-configmap.yaml` |
| Secrets | `headplane-secrets` (create manually; keys: cookie_secret, oidc_client_secret, headscale_api_key) |
