# Installing Mailu (mail server)

This guide covers installing [Mailu](https://mailu.io) on your K3s cluster via the Argo CD Application in this repo. Mailu provides webmail, admin UI, SMTP (with STARTTLS on 587), and IMAP.

**What you get:**

- Web UI at `https://mail.<your-domain>` (e.g. `https://mail.tukangketik.net`)
- Admin at `https://mail.<your-domain>/admin`
- Outgoing mail: SMTP on port **587** (STARTTLS); the repo does not expose legacy port 465 (SMTPS)
- Incoming: IMAP (POP3 is disabled in the default values)
- TLS for the web UI is handled by Traefik + cert-manager (Let's Encrypt); the Mailu front uses a separate Certificate for mail (port 587)

---

## Prerequisites

- **Cluster:** K3s with Argo CD, cert-manager, and Traefik already installed (see [deployment-infra.md](deployment-infra.md)).
- **cert-manager:** Let's Encrypt issuers (e.g. `letsencrypt-prod`) so the Mailu Certificate can be issued.
- **DNS:** A hostname for Mailu (e.g. `mail.tukangketik.net`) with an **A** record pointing to your VPS. Optional but recommended for delivery: **MX** record for your domain pointing to `mail.<your-domain>`, and **SPF** / **DKIM** (configured later in the Mailu admin UI).

---

## 1. Configure domain and hostnames

Edit **`deploy/argocd/apps/mailu/values.yaml`** and set your domain and mail hostname:

- **`domain`** – your primary domain (e.g. `tukangketik.net`). Used for the default admin account and mail domain.
- **`hostnames`** / **`mailu.hostnames`** – the hostname(s) for the web UI and Ingress (e.g. `mail.tukangketik.net`). Must match the DNS A record.

Example (already in the repo for `tukangketik.net`):

```yaml
domain: tukangketik.net
hostnames:
  - mail.tukangketik.net

mailu:
  domain: tukangketik.net
  hostnames:
    - mail.tukangketik.net
  # ... rest (existingSecret, initialAccount, etc.)
```

If you change the domain, also update **`mailu.initialAccount.domain`** and **`mailu.initialAccount.username`** (admin user) to match. Commit and push so Argo CD can sync.

---

## 2. Create required Secrets (before or right after first sync)

Mailu needs two secrets in the `mailu` namespace. Run these from the **repo root**.

### 2.1 Main Mailu secret (`mailu-secret`)

Contains the internal `secret-key` used by Mailu components. Create it once:

```bash
./scripts/create-mailu-secret.sh
```

Optional env: `MAILU_NAMESPACE` (default `mailu`), `MAILU_SECRET_KEY` (if you want to set the key yourself).

### 2.2 Initial admin account secret (`mailu-initial-account`)

This sets the password for the first admin user (e.g. `admin@tukangketik.net`). Required when `mailu.initialAccount.enabled: true` and `existingSecret: mailu-initial-account` in values.

```bash
./scripts/create-mailu-initial-account-secret.sh
```

The script will prompt for the admin password unless you set `MAILU_ADMIN_PASS`. After creating or updating this secret, restart the admin deployment so it picks up the account:

```bash
kubectl rollout restart deployment -n mailu -l app.kubernetes.io/component=admin
```

Then log in at **https://mail.<your-domain>/admin** as `admin@<your-domain>`.

---

## 3. Deploy the Mailu Application via Argo CD

The Mailu app is included in the app-of-apps kustomization (`deploy/argocd/apps/kustomization.yaml`). If you use the app-of-apps pattern:

1. Apply the apps (if not already):  
   `kubectl apply -k deploy/argocd/apps/`
2. In Argo CD, the **mailu** Application should appear. Open it → **Refresh** → **Sync**.

If you manage Applications manually, create the Application and then sync:

```bash
kubectl apply -f deploy/argocd/apps/mailu/mailu.application.yaml
# In Argo CD UI: mailu → Refresh → Sync
```

The Application deploys the Mailu Helm chart (wrapper chart in this repo) into the **mailu** namespace. The wrapper adds:

- A cert-manager **Certificate** for the mail hostnames → secret `mailu-certificates` (used by the Mailu front for TLS on port 587 and by Traefik for the web UI).
- A Traefik **IngressRoute** (CRD) for the web UI (backend port 80, TLS terminated at Traefik). Optionally, when [Authentik is enabled](#authentik-integration-optional), ForwardAuth protects the UI and routes `/outpost.goauthentik.io/*` to Authentik for SSO callbacks.

---

## 4. Wait for Certificate and pods

1. Certificate issuance can take 1–2 minutes. Check:
   ```bash
   kubectl get certificate -n mailu
   kubectl get secret mailu-certificates -n mailu
   ```
2. Once `mailu-certificates` exists, the **mailu-front** pod should leave `ContainerCreating` and start. Check pods:
   ```bash
   kubectl get pods -n mailu
   ```
3. If the front was stuck, restart it after the secret appears:
   ```bash
   kubectl delete pod -n mailu -l app.kubernetes.io/component=front
   ```

---

## 5. Log in and configure

- **Webmail:** https://mail.<your-domain>
- **Admin:** https://mail.<your-domain>/admin — log in as `admin@<your-domain>` with the password you set in step 2.2.

In the admin UI you can:

- Add more domains and users.
- Configure **DKIM** and **SPF** (see Mailu docs) and add the suggested DNS records for better deliverability.
- Adjust antispam, fetch accounts, etc.

---

## 6. Authentik integration (optional)

You can protect the Mailu web UI with [Authentik](https://goauthentik.io/) so users sign in via SSO instead of (or in addition to) local Mailu passwords.

### How it works

- **Traefik** uses **Forward Auth**: unauthenticated requests to `https://mail.<your-domain>` are sent to Authentik; after login, Authentik returns success and headers (e.g. `X-Authentik-Email`).
- **Mailu** is configured for **proxy (header) authentication**: it trusts requests from Traefik’s IP range and treats the header `X-Authentik-Email` as the authenticated user’s email.
- The repo uses a Traefik **IngressRoute** (not the standard Kubernetes Ingress) and an optional **ForwardAuth Middleware** when Authentik is enabled.

### Enable in values

In **`deploy/argocd/apps/mailu/values.yaml`**:

```yaml
mailu:
  authentik:
    enabled: true
    forwardAuthUrl: "https://auth.<your-auth-domain>/outpost.goauthentik.io/auth/traefik"
    backendNamespace: auth
    backendServiceName: authentik
    backendPort: 80
    proxyAuthWhitelist: "10.42.0.0/16"   # Cluster CIDR (must include Traefik)
    proxyAuthHeader: "X-Authentik-Email"
```

Adjust `forwardAuthUrl` to your Authentik host and ensure `proxyAuthWhitelist` includes the CIDR of your Traefik pods (e.g. K3s default `10.42.0.0/16`).

### Authentik setup

For a **step-by-step guide** (creating Application, Proxy Provider, Outpost, and access), see **[Authentik setup for Mailu (detailed)](authentik-mailu-setup.md)**.

Summary:

1. In Authentik, create an **Application** (e.g. name Mailu, Launch URL `https://mail.<your-domain>`).
2. Create a **Proxy Provider** with **Mode:** *Forward auth (Single application)* and **External host:** `https://mail.<your-domain>`. Attach it to the Application. Choose an **Authorization flow** that ends with redirect/consent.
3. In **Outposts**, ensure the **Embedded Outpost** (or your proxy outpost) includes this Application so it can serve `/outpost.goauthentik.io/auth/traefik`.
4. Give the right **users/groups** access to the Application (policy bindings) so they can open Mailu.

### Mailu users and domains

- Proxy auth only works for **existing** Mailu users: the value of `X-Authentik-Email` must match a Mailu user (e.g. `user@tukangketik.net`). Create the user (and domain) in the Mailu admin UI first, or use the same local admin account.
- To allow **password fallback** (e.g. for IMAP/SMTP), keep the initial admin account and create Mailu users with passwords; Authentik then only protects the **web** UI.

### Disable Authentik

Set `mailu.authentik.enabled: false` and sync. The IngressRoute will still be used, but without ForwardAuth or the `/outpost.goauthentik.io/` route.

---

## 7. Client configuration (outgoing mail)

Use **port 587 with STARTTLS** (not 465). The repo exposes submission on 587 only.

- **Server:** `mail.<your-domain>`
- **Port:** 587  
- **Encryption:** STARTTLS  
- **Username / password:** a Mailu user (e.g. `admin@<your-domain>` or a mailbox you created).

The Mailu client setup page may still show 465 in the UI; you can ignore that and use 587 as above. See [Runbooks – Mailu: Client setup shows 465](runbooks.md#client-setup-page-shows-465) for details.

---

## Summary checklist

- [ ] DNS A record for `mail.<your-domain>` pointing to the VPS
- [ ] `deploy/argocd/apps/mailu/values.yaml` updated with your `domain` and `hostnames`
- [ ] `./scripts/create-mailu-secret.sh` run
- [ ] `./scripts/create-mailu-initial-account-secret.sh` run (then restart admin deployment if needed)
- [ ] Argo CD **mailu** Application synced
- [ ] Certificate `mailu-certificates` and pods healthy in `mailu` namespace
- [ ] Log in at https://mail.<your-domain>/admin and set MX/SPF/DKIM if desired
- [ ] (Optional) [Authentik](#authentik-integration-optional): create Proxy Provider and set `mailu.authentik.enabled: true` if using SSO

---

## Troubleshooting

| Issue | Where to look |
| ----- | -------------- |
| 502 Bad Gateway on web UI | [Runbooks: 502 Bad Gateway](runbooks.md#502-bad-gateway-mailtukangketiknet) |
| Front stuck in ContainerCreating (secret not found) | [Runbooks: mailu-certificates](runbooks.md#front-stuck-in-containercreating--secret-mailu-certificates-not-found) |
| Cannot log in to admin / initial account | [Runbooks: Initial admin cannot log in](runbooks.md#initial-admin-cannot-log-in) |
| Client setup shows 465 | [Runbooks: Client setup 465](runbooks.md#client-setup-ui-shows-port-465-for-smtp) |
| Port 25 / external IP for receiving mail | [Runbooks: Port 25](runbooks.md#port-25-smtp-connection-timeout-from-outside) |
| Authentik: redirect loop or "Invalid redirect uri" | Ensure Proxy Provider **External host** is exactly `https://mail.<your-domain>`; ensure IngressRoute has the `/outpost.goauthentik.io/` route (priority &gt; main route). |

Full Mailu procedures: [Runbooks – Mailu](runbooks.md#mailu).
