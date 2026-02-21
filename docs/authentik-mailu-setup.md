# Authentik setup for Mailu (detailed)

This guide walks you through configuring [Authentik](https://goauthentik.io/) so that the Mailu web UI is protected by SSO (forward auth). Your Traefik IngressRoute already calls Authentik for auth and passes the user’s email to Mailu via headers; here we configure the **Application**, **Proxy Provider**, **Outpost**, and **access** in Authentik.

**Prerequisites:** Authentik is deployed and reachable (e.g. `https://auth.tukangketik.net`). Mailu values have `mailu.authentik.enabled: true` and the correct `forwardAuthUrl` (see [mailu-install.md](mailu-install.md#authentik-integration-optional)).

---

## 1. Log in to Authentik

1. Open the Authentik admin UI: **https://auth.tukangketik.net** (or your Authentik host).
2. Sign in with your Authentik admin account (the one you created when you first set up Authentik).

---

## 2. Create an Application

Applications are what users see (e.g. on “My applications”) and what you attach a Provider to.

1. Go to **Applications** → **Applications** (left sidebar).
2. Click **Create**.
3. Fill in:
   - **Name:** `Mailu` (or e.g. “Mail”).
   - **Slug:** `mailu` (used in URLs; keep it short and lowercase).
   - **Provider:** Leave empty for now; we’ll attach the Proxy Provider in the next step, or use “Create new” when creating the provider (see below).
   - **Launch URL:** `https://mail.tukangketik.net` (your Mailu URL). This is where users land when they open the app from Authentik.
   - **Icon / Publisher / Description:** Optional.
4. Click **Create**.

You now have an Application with no Provider. Next we create the Proxy Provider and link it.

---

## 3. Create the Proxy Provider (Forward Auth)

The Proxy Provider tells Authentik how to protect your app and which URL it’s protecting. For Traefik we use **Forward auth (single application)**.

1. Go to **Applications** → **Providers**.
2. Click **Create**.
3. Choose **Proxy Provider**.
4. Fill in:

   **Basic**
   - **Name:** `Mailu` (or same as the application name).
   - **Authorization flow:** Pick a flow that ends with redirect/consent.  
     - If you don’t have one: go to **Events** → **Flows**, duplicate the default “default-provider-authorization-implicit-consent” (or similar) and use it, or create a new flow that has “Redirect” or “Consent” at the end.
   - **Application:** Select the **Mailu** application you created in step 2.

   **Protocol settings (Proxy Provider)**
   - **Mode:** **Forward auth (Single application)**.  
     This is the mode for one app per domain (e.g. `mail.tukangketik.net`). Do **not** use “Forward auth (Domain level)” unless you want all apps on the same domain as Authentik.
   - **External host:** `https://mail.tukangketik.net`  
     Must match exactly the URL users use for Mailu (scheme + host, no path). This is used for redirects and cookie scope.
   - **Internal host (optional):** Leave empty unless you have a different internal URL. For our setup, Traefik forwards to Mailu directly; Authentik only does auth.
   - **Unauthenticated paths:** Leave empty unless you want to allow some paths without login (e.g. health checks). For Mailu you typically protect everything.

5. Click **Create**.

6. **Attach the Provider to the Application** (if you didn’t select it when creating):
   - Go to **Applications** → **Applications** → open **Mailu**.
   - Set **Provider** to the **Mailu** Proxy Provider you just created.
   - Save.

---

## 4. Ensure the Outpost serves this Application

Authentik uses an **Outpost** to handle proxy/forward-auth. The Helm chart usually runs an **embedded outpost** inside the Authentik server (same pod). That outpost must include your Mailu application.

1. Go to **Applications** → **Outposts**.
2. Open the **Embedded Outpost** (or the outpost you use for proxy apps). Its type should be **Proxy**.
3. In **Applications**, ensure **Mailu** is in the list. If not, add it and save.
4. Confirm the outpost is **Running** and **Connected** — see [How to ensure the outpost is Running and Connected](#how-to-ensure-the-outpost-is-running-and-connected) below.

The forward auth URL we use in Traefik is:

`https://auth.tukangketik.net/outpost.goauthentik.io/auth/traefik`

That is served by the same Authentik server that hosts the embedded outpost (same host, path `/outpost.goauthentik.io/...`). So no separate outpost URL is needed in Traefik; just the `forwardAuthUrl` in your Mailu values.

---

## How to ensure the outpost is Running and Connected

### In the Authentik UI

1. Go to **Applications** → **Outposts**.
2. In the outposts list you should see:
   - **Name** (e.g. “authentik Embedded Outpost”)
   - **Type** (Proxy)
   - **Status / State** — often a badge or column indicating whether the outpost is connected.
3. **Connected** means the outpost has established a WebSocket connection to the Authentik Core API and is sending healthchecks. If it shows **Disconnected** or a warning, the outpost cannot handle forward-auth until it reconnects.
4. For the **embedded outpost**, “Running” is the same as the Authentik server process: if the server pod is up, the embedded outpost process is running. Connection status is what you need to verify.

If your UI doesn’t show a clear “Connected” label, check the outpost **detail** page (click the outpost name); some versions show connection or last-seen time there.

### From the cluster (kubectl)

- **Authentik server (and embedded outpost) is running:**
  ```bash
  kubectl get pods -n auth -l app.kubernetes.io/name=authentik
  ```
  The server pod should be `Running`. The embedded outpost runs inside this pod; there is no separate outpost pod.

- **Server logs** (include outpost-related messages):
  ```bash
  kubectl logs -n auth deployment/authentik -c server --tail=100
  ```
  Look for errors about WebSockets, tokens, or “outpost”. A healthy embedded outpost will typically log connection or heartbeat activity.

### If the outpost shows Disconnected

1. **Restart the Authentik server** so the embedded outpost reconnects:
   ```bash
   kubectl rollout restart deployment/authentik -n auth
   ```
   Wait a minute, then refresh the Outposts page in the UI.

2. **Check Authentik is reachable from itself** (for the outpost’s API connection). If you changed the ingress host or TLS, ensure the server’s `authentik_host` / URL config matches how the outpost should reach the API (often the same as the public URL, e.g. `https://auth.tukangketik.net`).

3. **Review server logs** (command above) for authentication or network errors; fix any token or connectivity issue indicated there.

4. **If you use a separate (non-embedded) proxy outpost** (e.g. its own deployment), ensure that deployment is running, has the correct token/secret, and can reach the Authentik API URL. Then check again in **Applications** → **Outposts** for that outpost’s status.

Once the outpost is **Connected**, forward auth to `https://auth.tukangketik.net/outpost.goauthentik.io/auth/traefik` will be handled correctly for applications (like Mailu) that are assigned to that outpost.

---

## 5. Who can access Mailu (Policies)

By default, only users you give access to will pass the forward auth check. Users without access get a denial from Authentik instead of reaching Mailu.

1. Go to **Applications** → **Applications** → open **Mailu**.
2. Open the **Policy / Group / User Bindings** tab (or **Access** / **Authorization** depending on your Authentik version).
3. Add access:
   - **Option A – Everyone:** Add a policy that allows all users (e.g. “Allow all” expression policy), or bind the “Everyone” group if you have it.
   - **Option B – Specific users/groups:** Add the users or groups that should be able to open Mailu (e.g. group “mail-users” or individual users).

Users who are allowed will be redirected to Authentik to log in when they open `https://mail.tukangketik.net`; after login, Authentik returns success and Traefik forwards the request to Mailu with headers like `X-Authentik-Email`. Users without access will see an Authentik “Access denied” (or similar) and never reach Mailu.

---

## 6. Match Authentik users to Mailu users

Mailu uses the **email** header (`X-Authentik-Email`) as the authenticated user. So:

- The **Authentik user’s email** (in their profile) must match a **Mailu user’s email** (e.g. `user@tukangketik.net`).
- Create the **domain** and **user** in the Mailu admin UI first (or use the initial admin account). If the email doesn’t exist in Mailu, Mailu won’t have a mailbox for that user and may show an error or prompt for password.

So for each person who should use Mailu via Authentik:

1. In **Authentik:** Set their **email** in the user profile (and give them access to the Mailu application as in step 5).
2. In **Mailu admin:** Ensure the domain exists and create a user with the **same email** (and set a password if they also use IMAP/SMTP with password).

---

## 7. Test the flow

1. In a private/incognito window (or after logging out of Authentik), open **https://mail.tukangketik.net**.
2. You should be redirected to Authentik to log in (e.g. `https://auth.tukangketik.net/...`).
3. Log in with a user that has access to the Mailu application.
4. After login, you should be redirected back to **https://mail.tukangketik.net** and see the Mailu UI (webmail or admin) as that user — provided that email exists as a Mailu user.

If you get a redirect loop or “Invalid redirect uri”:

- Confirm **External host** on the Proxy Provider is exactly `https://mail.tukangketik.net` (no trailing slash, correct scheme and host).
- Confirm your Traefik IngressRoute has the **higher-priority** route for `PathPrefix(/outpost.goauthentik.io/)` so the callback goes to Authentik, not Mailu (see [mailu-install.md](mailu-install.md)).

---

## 8. Logging out

To sign out from Mailu’s SSO session (Authentik cookie for this app):

- Open: **https://mail.tukangketik.net/outpost.goauthentik.io/sign_out**

That invalidates the Authentik session for this provider; the user will be asked to log in again on the next visit to Mailu.

---

## Quick reference

| Item | Value (example) |
|------|------------------|
| Authentik URL | `https://auth.tukangketik.net` |
| Mailu URL | `https://mail.tukangketik.net` |
| Proxy Provider mode | Forward auth (Single application) |
| External host (Provider) | `https://mail.tukangketik.net` |
| Forward auth URL (Traefik) | `https://auth.tukangketik.net/outpost.goauthentik.io/auth/traefik` |
| Header Mailu reads | `X-Authentik-Email` |
| Sign-out URL | `https://mail.tukangketik.net/outpost.goauthentik.io/sign_out` |

For high-level Mailu + Authentik wiring, see [mailu-install.md – Authentik integration](mailu-install.md#authentik-integration-optional).
