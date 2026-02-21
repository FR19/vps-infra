# Authentik SSO for Argo CD

This guide configures [Argo CD](https://argo-cd.readthedocs.io/) to use [Authentik](https://goauthentik.io/) as the OIDC provider for SSO login (in addition to or instead of the built-in admin account). Paths are relative to the infra repository root.

**Prerequisites:** Authentik is deployed and reachable (e.g. `https://auth.tukangketik.net`). Argo CD is deployed and its URL is known (e.g. `https://argocd.tukangketik.net`).

---

## Overview

- **Argo CD** supports native OIDC: you set `url` and `oidc.config` in the `argocd-cm` ConfigMap. The callback URL Argo CD uses is **`https://<argocd-url>/auth/callback`** (native OIDC; some older docs mention `/api/dex/callback`, but current versions use `/auth/callback`).
- **Authentik** acts as the OAuth2/OIDC provider: you create an OAuth2/OpenID Provider and an Application, then use the issuer URL, client ID, and client secret in Argo CD.
- Optional: use **groups** from Authentik for Argo CD RBAC (your repo already has `scopes: "[groups]"` in RBAC config).

---

## 1. Create the OAuth2/OIDC Provider in Authentik

1. Log in to the Authentik admin UI: **https://auth.tukangketik.net** (or your Authentik host).
2. Go to **Applications** → **Providers**.
3. Click **Create** and choose **OAuth2/OpenID Provider**.
4. Fill in:
   - **Name:** `Argo CD` (or e.g. `argocd`).
   - **Authorization flow:** Choose a flow that includes consent/redirect (e.g. default provider authorization flow).
   - **Application:** Leave empty for now, or create the Application first (step 2) and select it.
   - **Client type:** **Confidential**.
   - **Redirect URIs:** Add exactly:
     - `https://argocd.tukangketik.net/auth/callback`
     - If you use a different Argo CD URL, use `https://<your-argocd-host>/auth/callback`.
   - **Signing Key:** Use an existing RS256 key or create one under **System** → **Certificates**.
5. Click **Create**.
6. After creation, open the provider and copy:
   - **Client ID**
   - **Client Secret** (show and copy; you’ll need it for Argo CD).
   - **Issuer URL** (and **OpenID configuration URL** if shown).  
     The issuer is typically: `https://auth.tukangketik.net/application/o/<provider-slug>/`

---

## 2. Create an Application in Authentik (optional but recommended)

1. Go to **Applications** → **Applications**.
2. Click **Create**.
3. Set:
   - **Name:** `Argo CD`
   - **Slug:** `argocd` (used in URLs).
   - **Provider:** Select the **Argo CD** OAuth2 provider you created in step 1.
   - **Launch URL:** `https://argocd.tukangketik.net` (your Argo CD URL).
4. Save.

Users will see Argo CD in “My applications” and can open it from Authentik.

---

## 3. Groups for Argo CD RBAC (optional)

This section is optional. It explains how to give **different permissions** to different users based on Authentik **groups** (e.g. some users get full admin, others only read-only).

### What this gives you

- **Without groups:** Every user who logs in via Authentik gets the same Argo CD role (your current default is `role:admin`).
- **With groups:** You define groups in Authentik (e.g. `argocd-admins`, `argocd-viewers`), assign users to those groups, then in Argo CD you say “users in group X get role admin, users in group Y get role readonly”. Argo CD reads the `groups` claim from the OIDC token and applies the matching role.

Your repo already has `configs.rbac.scopes: "[groups]"`, which tells Argo CD to use the **groups** claim from the token for RBAC. You only need to: (1) put group names into that claim from Authentik, and (2) define in Argo CD which group gets which role.

---

### Step 3a: Create groups and assign users in Authentik

1. In Authentik, go to **Directory** → **Groups**.
2. Create groups whose **names** you will use in Argo CD policy, e.g.:
   - `argocd-admins` — users who can sync, delete, change apps.
   - `argocd-viewers` — users who can only view apps (read-only).
3. Go to **Directory** → **Users**, open each user, and add them to the appropriate group(s).  
   The exact group **name** (e.g. `argocd-admins`) must match what you write in Argo CD’s policy in step 3c.

---

### Step 3b: Put groups into the OIDC token (Authentik)

Argo CD needs a **groups** claim in the ID token (e.g. `"groups": ["argocd-admins"]`). Authentik does not always add this by default; you add it with a **scope mapping**.

1. In Authentik, go to **Customization** → **Property Mappings**.
2. Click **Create** and choose **Scope Mapping**.
3. Configure:
   - **Name:** e.g. `Argo CD – groups`.
   - **Scope name:** `groups` (this becomes the scope/claim name Argo CD requests and reads).
   - **Expression:** use the following so the user’s group names are sent in the token:

     ```python
     return {
         "groups": [group.name for group in request.user.ak_groups.all()]
     }
     ```

4. Save.
5. Open your **Argo CD** OAuth2/OpenID Provider (Applications → Providers).
6. In **Protocol settings** → **Scopes** (or **Scope Mappings**), add the **groups** scope and attach the scope mapping you just created so that when the client requests the `groups` scope, this mapping runs and fills the `groups` claim.

We already request `groups` in Argo CD’s `oidc.config` (`requestedScopes` includes `groups`), so once this mapping is attached, the token will contain the user’s Authentik group names.

---

### Step 3c: Map groups to roles in Argo CD (policy.csv)

Argo CD RBAC uses a small “policy file” in **policy.csv** format with two types of lines:

- **`p, ...`** — **Policy rule:** “this role is allowed this action on this object.”
- **`g, ...`** — **Grant:** “this user or **group** gets this role.”

So you first define what each **role** is allowed to do (`p`), then who (which **group**) gets which role (`g`).

**Example:** “Members of group `argocd-admins` get full admin; members of group `argocd-viewers` get read-only; everyone else gets no access.”

In `deploy/argocd/apps/argocd/values.yaml`, under `configs.rbac`, you already have something like:

```yaml
policy.csv: |
  p, role:admin, applications, *, vps-platform/*, allow
policy.default: role:admin
policy.matchMode: glob
scopes: "[groups]"
```

To use groups instead of giving everyone admin:

1. **Define permissions for each role** (the `p` lines):
   - `role:admin` — full access (already there).
   - `role:readonly` — only get/list (view) applications.

2. **Grant roles by group** (the `g` lines):
   - `g, argocd-admins, role:admin` — Authentik group `argocd-admins` gets admin.
   - `g, argocd-viewers, role:readonly` — Authentik group `argocd-viewers` gets readonly.

3. **Default for users not in any of these groups:** set `policy.default` to a role that has no or minimal access, or leave it as `role:admin` if you want “everyone else” to still be admin until you’re ready to lock it down.

**Full example** (replace the existing `policy.csv` block with this if you want group-based RBAC):

```yaml
configs:
  rbac:
    policy.csv: |
      # What each role can do (p = policy)
      p, role:admin, applications, *, vps-platform/*, allow
      p, role:readonly, applications, get, vps-platform/*, allow
      p, role:readonly, applications, list, vps-platform/*, allow
      # Who gets which role (g = grant by group name from Authentik)
      g, argocd-admins, role:admin
      g, argocd-viewers, role:readonly
    policy.default: role:readonly   # or "" to deny by default; use role:admin to keep current behaviour
    policy.matchMode: glob
    scopes: "[groups]"
```

Group names in the `g` lines (e.g. `argocd-admins`) must match the **names** of the groups in Authentik exactly (case-sensitive). After you sync the Argo CD application, users in `argocd-admins` will have full access; users in `argocd-viewers` will only be able to view.

---

## 4. Configure Argo CD (Helm values)

**Security:** If you ever committed the OIDC client secret to git, rotate it in Authentik (generate a new client secret in the provider and revoke the old one), then set the new secret using one of the methods below.

In this repo, Argo CD is managed by the Helm chart under `deploy/argocd/apps/argocd/`. The following is added in `values.yaml`:

- **`configs.cm.url`** – Argo CD’s public URL (must match what you put in Authentik redirect URIs).
- **`configs.cm.oidc.config`** – OIDC config block with Authentik’s issuer, client ID, and client secret reference.
- **`configs.secret.extra`** – The OIDC client secret is stored in the Argo CD secret and referenced as `$oidc.argocd.clientSecret` in the config (so the secret key is `oidc.argocd.clientSecret`).

You **must** set the client secret in the Argo CD secret. The file `values-oidc-secret.yaml` is a **Helm values file** (used by `helm upgrade -f ...`), **not** a Kubernetes manifest — you do **not** use `kubectl apply` on it. Two ways to set the secret:

### Option A: Set the secret via kubectl (recommended)

After Argo CD has synced at least once, patch the existing `argocd-secret` in the cluster. The secret must be base64-encoded:

```bash
# Replace YOUR_CLIENT_SECRET with the value from Authentik (Protocol → Client secret)
kubectl patch secret argocd-secret -n argocd --type='merge' -p "{\"stringData\":{\"oidc.argocd.clientSecret\":\"YOUR_CLIENT_SECRET\"}}"
```

No need to base64-encode manually: `stringData` accepts plain text and Kubernetes encodes it. Restart the Argo CD server so it picks up the new secret:

```bash
kubectl rollout restart deployment argocd-server -n argocd
```

**Note:** If Argo CD auto-syncs again, the Helm chart may overwrite this key (because `values.yaml` includes it with an empty value). If the secret disappears after a sync, run the `kubectl patch` command again, or use Option B so the value comes from a values file.

### Option B: Use the values file and have Argo CD use it

1. Edit `deploy/argocd/apps/argocd/values-oidc-secret.yaml` and set `oidc.argocd.clientSecret` to your real client secret.
2. **Do not commit that secret.** Add the file to `.gitignore` or use a copy (e.g. `values-oidc-secret.local.yaml`) that you keep only on your machine.
3. Make Argo CD use this file when rendering the chart: in `deploy/argocd/apps/argocd/argocd.application.yaml`, under `spec.source.helm`, add:

   ```yaml
   valueFiles:
     - values.yaml
     - values-oidc-secret.yaml
   ```

   If the file is not in the repo (e.g. you use a local-only file), Argo CD cannot see it when it syncs from git — so this option only works if the file is in the repo (use encrypted secrets / Sealed Secrets if you need the value in git) or if you run `helm upgrade` manually from a machine that has the file.

---

## 5. Disable the built-in admin (optional)

After SSO works and you’ve confirmed at least one user can log in:

1. In `deploy/argocd/apps/argocd/values.yaml`, set:
   - `configs.cm.admin.enabled: false`
2. Sync the Argo CD application so the change is applied.

Keep a break-glass method (e.g. local admin or a second OIDC account) before disabling the admin.

---

## 6. Disable Dex (optional)

If you use only native OIDC (Authentik), you can turn off Dex to simplify the stack:

- In `values.yaml` set `dex.enabled: false`.
- Sync the Argo CD app.

---

## Troubleshooting

### "invalid_client" / "Client authentication failed"

Authentik returns this when the **client secret** Argo CD sends is wrong, empty, or not sent. Common causes:

1. **Secret not set or overwritten**  
   The value in the cluster must be the exact **Client secret** from Authentik (Applications → Providers → your Argo CD provider → show client secret). If you never ran the `kubectl patch` from [Option A](#option-a-set-the-secret-via-kubectl-recommended), or Argo CD synced and overwrote the secret, the server will send an empty or wrong secret.

2. **Argo CD server not restarted**  
   The server reads the secret at startup. After patching the secret you must restart it:
   ```bash
   kubectl rollout restart deployment argocd-server -n argocd
   ```

3. **Wrong secret key name**  
   The key in `argocd-secret` must be exactly **`oidc.argocd.clientSecret`** (same as in `oidc.config`: `$oidc.argocd.clientSecret`).

**Verify the secret in the cluster:**

```bash
# Print the current value (should be your Authentik client secret, no extra spaces/newlines)
kubectl get secret argocd-secret -n argocd -o go-template='{{index .data "oidc.argocd.clientSecret"}}' | base64 -d
echo
```

- If this is **empty** or wrong: patch again with the exact value from Authentik, then restart the server:
  ```bash
  kubectl patch secret argocd-secret -n argocd --type='merge' -p "{\"stringData\":{\"oidc.argocd.clientSecret\":\"YOUR_EXACT_CLIENT_SECRET_FROM_AUTHENTIK\"}}"
  kubectl rollout restart deployment argocd-server -n argocd
  ```
- In Authentik, ensure the provider is **Confidential** and the client secret there matches what you put in the cluster (regenerate in Authentik if needed, then update the cluster and restart again).

---

## Summary

| Item            | Value / location |
|-----------------|------------------|
| Argo CD URL     | `https://argocd.tukangketik.net` |
| Callback URL    | `https://argocd.tukangketik.net/auth/callback` |
| Authentik admin | `https://auth.tukangketik.net` |
| Issuer          | From Authentik provider, e.g. `https://auth.tukangketik.net/application/o/argocd/` |
| Secret key      | `oidc.argocd.clientSecret` in the Argo CD secret |

After configuration, open Argo CD and choose “Login via Authentik” (or the name you gave in `oidc.config`). You’ll be redirected to Authentik to sign in, then back to Argo CD.
