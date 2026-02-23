# Headscale VPN and VPN-only Argo CD

This guide describes deploying [Headscale](https://headscale.net/) as the Tailscale control server, connecting the VPS and client devices to the tailnet, and restricting Argo CD to VPN-only access. All paths are relative to the **infra repository root**.

## Hostnames

| Service | URL | Notes |
|---------|-----|--------|
| Headscale (public) | `https://headscale.tukangketik.net` | Control plane API |
| Headplane (Web UI) | `https://headplane.tukangketik.net` | Admin UI for Headscale |
| MagicDNS base | `vpn.tukangketik.net` | Tailnet MagicDNS suffix |
| Argo CD (VPN-only) | `https://argocd.tukangketik.net` | On VPN: resolves to tailnet IP and is allowed; off VPN: blocked |

---

## Contents

1. [Deploy Headscale and sync](#1-deploy-headscale-and-sync)
2. [Bootstrap Headscale: user and pre-auth keys](#2-bootstrap-headscale-user-and-pre-auth-keys)
3. [Firewall and Tailscale on the VPS](#3-firewall-and-tailscale-on-the-vps)
4. [Connect the VPS to Headscale](#4-connect-the-vps-to-headscale)
5. [Set Argo CD DNS extra record in Headscale](#5-set-argocd-dns-extra-record-in-headscale) (includes [Custom DNS / tailscale-dns](#51-custom-dns-coredns--single-resolver-no-split-dns-quirks))
6. [Enroll phone and laptop](#6-enroll-phone-and-laptop) (includes [Exit node](#65-exit-node-vps-as-exit-node))
7. [Enable VPN-only Argo CD (Traefik middleware)](#7-enable-vpn-only-argocd-traefik-middleware)
8. [Break-glass: regain Argo CD access if locked out](#8-break-glass-regain-argocd-access-if-locked-out)
9. [Rotating pre-auth keys](#9-rotating-pre-auth-keys-reset-and-use-a-new-key)
10. [Reference](#10-reference)
11. [Headplane Web UI](#11-headplane-web-ui)
12. [ACL policy (database mode)](#12-acl-policy-database-mode)
13. [Headscale version and database migration](#13-headscale-version-and-database-migration)
14. [Troubleshooting: fetch control key / context canceled](#14-troubleshooting-fetch-control-key-context-canceled)
15. [Troubleshooting: VPS cannot access anything](#15-troubleshooting-vps-cannot-access-anything)
16. [Troubleshooting: Laptop not using Tailscale DNS](#16-troubleshooting-laptop-not-using-tailscale-dns-system-still-shows-100141-etc)
17. [Troubleshooting: Phone on VPN but Argo CD 403](#17-troubleshooting-phone-on-vpn-but-argocd-returns-403-forbidden)
18. [Troubleshooting: headscale returns 404](#18-troubleshooting-headscaletukangketiknet-returns-404)
19. [Troubleshooting: Cannot access Argo CD with Tailscale up](#19-troubleshooting-cannot-access-argocd-with-tailscale-up-middleware-and-ingress-in-place)

---

## 1. Deploy Headscale and sync

1. Ensure DNS has an **A record** for `headscale.tukangketik.net` pointing to your VPS.
2. Push the repo (or apply the app-of-apps) so Argo CD picks up the new Headscale app.
3. In Argo CD UI, sync the **headscale** application (namespace `headscale`). Wait until the Deployment is healthy and the Ingress has a certificate.
4. Confirm: `https://headscale.tukangketik.net` returns the Headscale API (e.g. "Hello from Headscale" or similar).

**If Headscale fails with:** `failed to get DERPMap: ... x509: certificate is valid for ... traefik.default, not controlplane.tailscale.com` — outbound HTTPS from the cluster is being intercepted. The repo uses **embedded DERP only** (no remote URL). Required settings in `deploy/argocd/apps/headscale/values.yaml`: `HEADSCALE_DERP_SERVER_ENABLED`, `HEADSCALE_DERP_SERVER_STUN_LISTEN_ADDR` (0.0.0.0:3478), `HEADSCALE_DERP_SERVER_PRIVATE_KEY_PATH` (/var/lib/headscale/derp_server_private.key, on the same persistent volume), `HEADSCALE_DERP_SERVER_IPV4` (your VPS public IPv4). Use `HEADSCALE_DERP_URLS: ""` (empty string) for no remote DERP; do not use `"[]"` (Headscale/viper then treats it as a single URL and fails). Open **UDP 3478** on the firewall (e.g. `vps-setup/02-firewall.sh`).

**Exposing embedded DERP (UDP 3478) to the internet:** The chart does not bind the pod to the node’s port 3478. So after sync, run this once so the Headscale pod accepts UDP 3478 on the VPS IP (the patch is re-applied by Argo CD if the deployment is recreated; if you upgrade the chart and the deployment template changes, re-run the patch if 3478 stops working):

```bash
kubectl patch deployment headscale -n headscale --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/ports/-","value":{"name":"derp","containerPort":3478,"protocol":"UDP","hostPort":3478}}]'
```

Then ensure UDP 3478 is allowed on the VPS firewall (see above).

---

## 2. Bootstrap Headscale: user and pre-auth keys

Run these from a machine that can `kubectl` into the cluster (e.g. SSH tunnel to the VPS and use kubeconfig).

**Create a user (e.g. `fakhrur`):**
```bash
kubectl exec -n headscale deploy/headscale -- headscale users create fakhrur
```
(The pod is configured with `HEADSCALE_CONFIG=/var/lib/headscale/config.yaml` so the CLI finds the config. If you see "Config File ... Not Found", pass it explicitly: `headscale --config /var/lib/headscale/config.yaml users create fakhrur`.)

**Pre-auth key for the VPS node (reusable, tag `tag:vps`, long-lived so the VPS does not need re-auth):**
```bash
kubectl exec -n headscale deploy/headscale -- headscale preauthkeys create --user fakhrur --reusable --tag vps --expiration 87600h --output
```
(`--expiration 87600h` is ~10 years; Headscale has no “never expire”, so use a long duration. Omit `--expiration` only for short-lived keys, which default to 1h.)
Save the printed key; you will use it in step 4.

**Pre-auth keys for phone and laptop (optional: ephemeral for one-time use):**
```bash
# Phone (reusable so you can reinstall the app)
kubectl exec -n headscale deploy/headscale -- headscale preauthkeys create --user fakhrur --reusable --output

# Laptop (reusable)
kubectl exec -n headscale deploy/headscale -- headscale preauthkeys create --user fakhrur --reusable --output
```
Store each key securely; you will enter them in the Tailscale app on each device.

---

## 3. Firewall and Tailscale on the VPS

- **UDP 41641** must be open for Tailscale WireGuard. The script `vps-setup/02-firewall.sh` includes this. If the firewall was configured before that change, run:
  ```bash
  sudo ufw allow 41641/udp comment 'Tailscale WireGuard'
  sudo ufw reload
  ```

- **Install Tailscale client on the VPS host** (once):
  ```bash
  cd vps-setup
  sudo bash 08-tailscale-install.sh
  ```

---

## 4. Connect the VPS to Headscale

On the VPS host (replace `YOUR_VPS_PREAUTH_KEY` with the key from step 2):

```bash
sudo tailscale up \
  --login-server=https://headscale.tukangketik.net \
  --accept-dns=false \
  --authkey=YOUR_VPS_PREAUTH_KEY \
  --hostname=vps
```

Use **`--accept-dns=false`** on the VPS so the host keeps normal DNS; if Tailscale logs out or fails, the VPS can still resolve names and stay reachable (see §15). Other devices (laptop, phone) should use Tailscale DNS for MagicDNS.

Confirm the node appears in Headscale:
```bash
kubectl exec -n headscale deploy/headscale -- headscale nodes list
```
Note the **Tailnet IP** of the VPS node (e.g. `100.64.x.y`). You will use it in step 5.

**Static Tailnet IP for the VPS:** Headscale has no official “set static IP” CLI. With default **sequential** allocation, the first registered node often gets `100.64.0.1`; register the VPS first if you want a stable IP. To force a specific IP (e.g. `100.64.0.1`), you can use an **unsupported** database edit: back up the Headscale DB, then update the VPS node’s IPv4 in the SQLite database, restart Headscale, and reconnect the VPS. See [§5.2 Static Tailnet IP (advanced)](#52-static-tailnet-ip-for-the-vps-advanced) for steps.

---

## 5. Set Argo CD DNS extra record in Headscale

So that when devices are on VPN, `argocd.tukangketik.net` resolves to the VPS Tailnet IP (not the public IP):

1. In `deploy/argocd/apps/headscale/values.yaml`, under `configMaps.dns.data.records`, set the A record to the VPS Tailnet IP from step 4 (see example in the file).
2. **Split DNS** is configured so the Tailscale client routes `*.tukangketik.net` to MagicDNS (100.100.100.100). That way the client asks Headscale for `argocd.tukangketik.net` and gets the extra record (Tailnet IP). Without this, the client would use global DNS (e.g. 1.1.1.1) for that domain and get the public IP. The values set `HEADSCALE_DNS_NAMESERVERS_SPLIT: '{"tukangketik.net": ["100.100.100.100"]}'`.
3. Commit, push, and let Argo CD sync the headscale app (or restart the headscale deployment so it reloads the config).
4. On the **laptop** (and other clients), ensure **Use Tailscale DNS** is enabled (and **Override local DNS** if you want all DNS to follow the tailnet). Then from a VPN-connected device, verify: `ping argocd.tukangketik.net` (or `getent hosts argocd.tukangketik.net` / macOS: `dscacheutil -q host -a name argocd.tukangketik.net`) shows the Tailnet IP (e.g. `100.64.x.y`), not the public IP.

### 5.1 Custom DNS (CoreDNS) — single resolver, no split-DNS quirks

Headscale does not forward non-MagicDNS queries, so tools like `nslookup` that send all queries to 100.100.100.100 get SERVFAIL for domains like `google.com`. To fix this, the repo deploys a **custom CoreDNS** (`tailscale-dns` app) that:

- Serves `*.tukangketik.net` from a hosts file (e.g. `argocd.tukangketik.net` → 100.64.0.1)
- Forwards all other domains to 94.140.14.14, 8.8.8.8, etc.

Headscale is configured to send **100.64.0.1** as the only nameserver, so clients use this CoreDNS for everything. No split DNS on the client; `nslookup`, `curl`, and the browser all behave consistently.

**Setup:**

1. Sync the **tailscale-dns** app in Argo CD (it creates a LoadBalancer Service on port 53).
2. Open **UDP/TCP 53** on the VPS firewall (`vps-setup/02-firewall.sh` includes this).
3. Run the iptables forward script so 100.64.0.1:53 reaches the cluster: `sudo bash vps-setup/09-argocd-tailscale-ip-forward.sh`
4. Add or edit records in `deploy/argocd/apps/tailscale-dns/manifests/configmap.yaml` under `tukangketik.hosts` (e.g. `argocd`, `headscale`, `headplane`, `auth`, `mail`). Sync the app after changes.

**MagicDNS device names** (e.g. `laptop.vpn.tukangketik.net`) are not in the hosts file by default. Add them manually if needed, or use Headscale’s MagicDNS for those only (more complex).

### 5.2 Static Tailnet IP for the VPS (advanced)

Headscale does not provide a CLI to assign a fixed Tailnet IP to a node. Two options:

**Option A – Rely on sequential allocation (simplest)**  
With default `prefixes.allocation: sequential`, the first node often gets `100.64.0.1`. Register the VPS first and avoid deleting/re-adding it if you want that IP to stay stable. Not guaranteed if you add or remove other nodes.

**Option B – Set IP via database (unsupported)**  
You can write the desired IP (e.g. `100.64.0.1`) into Headscale’s SQLite DB. Schema can change between versions. **You must stop Headscale** while editing the DB to avoid corruption.

**Step-by-step: edit the database directly**

1. **Back up the DB** (while Headscale is still running):
   ```bash
   kubectl exec -n headscale deploy/headscale -- cat /var/lib/headscale/db.sqlite > headscale-db-backup-$(date +%Y%m%d).sqlite
   ```

2. **Find the PVC** that holds the Headscale data:
   ```bash
   kubectl get pvc -n headscale
   ```
   Use the PVC that is bound and likely named after the release (e.g. `headscale-config` or `config-headscale`). Set it in a variable:
   ```bash
   PVC_NAME=config-headscale   # replace with the actual name from the previous command
   ```

3. **Scale down Headscale** so nothing is writing to the DB:
   ```bash
   kubectl scale deployment headscale -n headscale --replicas=0
   kubectl wait --for=delete pod -l app.kubernetes.io/name=headscale -n headscale --timeout=60s || true
   ```

4. **Run a temporary pod** that mounts the same PVC and has `sqlite3`:
   ```bash
   kubectl run -n headscale headscale-db-edit --rm -i --restart=Never \
     --image=alpine:3.19 \
     --overrides='{"spec":{"containers":[{"name":"db","image":"alpine:3.19","command":["sleep","3600"],"volumeMounts":[{"name":"data","mountPath":"/var/lib/headscale"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"'"$PVC_NAME"'"}}]}}'
   ```
   Leave this command running (it keeps the pod alive). In **another terminal**, continue with step 5.

   If your chart uses a different PVC name (e.g. `headscale-headscale`), replace `$PVC_NAME` in the `claimName` above.

5. **In the second terminal**, install sqlite in the pod and open the DB (replace `$PVC_NAME` if you used a different value):
   ```bash
   kubectl exec -n headscale headscale-db-edit -- apk add --no-cache sqlite
   kubectl exec -n headscale headscale-db-edit -- sqlite3 /var/lib/headscale/db.sqlite ".tables"
   ```
   Look for a table like `nodes` or `machines`. Then list nodes and their IPs (common column names are `hostname` and `ipv4`; Headscale 0.28 may use different names):
   ```bash
   kubectl exec -n headscale headscale-db-edit -- sqlite3 /var/lib/headscale/db.sqlite ".schema nodes"
   kubectl exec -n headscale headscale-db-edit -- sqlite3 /var/lib/headscale/db.sqlite "SELECT id, hostname, ipv4 FROM nodes;"
   ```
   If the column is not `ipv4` (e.g. `ip_address`), use the name from `.schema nodes`.

6. **Set the VPS node to the desired IP** (e.g. `100.64.0.1`). The IP must be in `100.64.0.0/10` and not used by another row:
   ```bash
   kubectl exec -n headscale headscale-db-edit -- sqlite3 /var/lib/headscale/db.sqlite "UPDATE nodes SET ipv4 = '100.64.0.1' WHERE hostname = 'vps';"
   ```
   Verify:
   ```bash
   kubectl exec -n headscale headscale-db-edit -- sqlite3 /var/lib/headscale/db.sqlite "SELECT id, hostname, ipv4 FROM nodes;"
   ```

7. **Stop the temporary pod** by going back to the first terminal and pressing `Ctrl+C`, or delete it:
   ```bash
   kubectl delete pod -n headscale headscale-db-edit --force --grace-period=0 2>/dev/null || true
   ```

8. **Scale Headscale back up**:
   ```bash
   kubectl scale deployment headscale -n headscale --replicas=1
   ```

9. **On the VPS:** Reconnect so the node gets the new IP:  
   `sudo tailscale up --login-server=https://headscale.tukangketik.net --accept-dns=false --hostname=vps`

10. **Update the extra record** in `deploy/argocd/apps/headscale/values.yaml`: set the `argocd.tukangketik.net` A record to the chosen IP (e.g. `100.64.0.1`), then sync the headscale app.

This method is unsupported and may break on Headscale upgrades; prefer Option A when possible.

---

## 6. Enroll phone and laptop

- **Phone:** Install the Tailscale app (iOS/Android), then use “Log in with key” and paste the pre-auth key you created for the phone. Ensure “Use Tailscale DNS” (or equivalent) is on so MagicDNS and the extra record apply.
- **Laptop:** Install Tailscale for your OS, then run (or use the GUI):
  ```bash
  tailscale up --login-server=https://headscale.tukangketik.net --authkey=YOUR_DEVICE_PREAUTH_KEY
  ```

---

### 6.5 Exit node (VPS as exit node)

To send **all** your laptop’s internet traffic (including `curl`) out via the VPS so it appears from the VPS IP:

1. **On the VPS:** Advertise the node as an exit node and ensure IP forwarding is on:
   ```bash
   sudo tailscale set --advertise-exit-node
   # IP forwarding (often already enabled on a VPS):
   echo 'net.ipv4.ip_forward = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
   echo 'net.ipv6.conf.all.forwarding = 1' | sudo tee -a /etc/sysctl.d/99-tailscale.conf
   sudo sysctl -p /etc/sysctl.d/99-tailscale.conf
   ```

2. **On Headscale:** Approve the exit node so clients can use it (from a machine with `kubectl`). **If you skip this, the laptop cannot use the VPS as exit node.**
   ```bash
   kubectl exec -n headscale deploy/headscale -- headscale nodes list-routes
   ```
   Find the VPS node (hostname `vps` or similar) and note its **ID**. The exit node will show **Available**: `0.0.0.0/0` and `::/0`; **Approved** should be empty until you approve. Then approve (approving `0.0.0.0/0` also approves `::/0`):
   ```bash
   kubectl exec -n headscale deploy/headscale -- headscale nodes approve-routes --identifier <VPS_NODE_ID> --routes 0.0.0.0/0
   ```
   Replace `<VPS_NODE_ID>` with the ID from `list-routes` (e.g. `1`). Verify: run `list-routes` again; the VPS row should show **Approved** and **Serving** filled.
   **Older Headscale:** If your version has `routes list` instead of `nodes list-routes`, use:
   `headscale routes list` then `headscale routes enable -r <route_id>` for each route ID (IPv4 and IPv6).

3. **On the laptop (CLI):** Tell Tailscale to use the VPS as the exit node:
   ```bash
   tailscale set --exit-node=vps
   ```
   Use the VPS **MagicDNS name** (e.g. `vps` or `vps.vpn.tukangketik.net`) or the VPS **Tailnet IP** (e.g. `100.64.x.y`). To see available exit nodes: `tailscale status`.
   To stop using the exit node:
   ```bash
   tailscale set --exit-node=
   ```

Until you run **step 3** on the laptop, traffic stays direct from the laptop; the VPS is only *offering* to be an exit node. After `tailscale set --exit-node=vps`, `curl ifconfig.me` (or similar) from the laptop should show the VPS’s public IP.

---

## 6.6 Troubleshooting: Exit node not working (traffic still uses my IP)

If you set `--advertise-exit-node` on the VPS and `--exit-node=vps` on the laptop but `curl ifconfig.me` (or similar) still shows your laptop’s IP:

1. **Approve the exit node on Headscale (most common cause)**  
   The exit node must be **approved** on the control server before any client can use it. Check and approve:
   ```bash
   kubectl exec -n headscale deploy/headscale -- headscale nodes list-routes
   ```
   Find the row for your VPS (hostname `vps`). If **Approved** is empty, approve it (use the node **ID** from the first column):
   ```bash
   kubectl exec -n headscale deploy/headscale -- headscale nodes approve-routes --identifier <VPS_NODE_ID> --routes 0.0.0.0/0
   ```
   Then on the laptop run `tailscale set --exit-node=vps` again and retry `curl ifconfig.me`.

2. **Confirm the laptop is using the exit node**  
   On the laptop: `tailscale status`. You should see the exit node in use (e.g. “Exit node: vps” or similar). If not, run:
   `tailscale set --exit-node=vps`  
   Use the exact hostname or MagicDNS name (e.g. `vps` or `vps.vpn.tukangketik.net`). To see available exit nodes: `tailscale status` lists them.

3. **IP forwarding on the VPS**  
   The VPS must have IP forwarding enabled. On the VPS:
   ```bash
   sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
   ```
   Both should be `1`. If not, add to `/etc/sysctl.d/99-tailscale.conf` and run `sysctl -p` (see step 1 in §6.5).

4. **macOS: enable Tailscale DNS**  
   On **macOS** (and iOS), exit nodes often do not work unless **Use Tailscale DNS** is enabled (and, if shown, **Override local DNS**). This is due to Apple's Network Extension behavior. In the Tailscale menu → Settings, turn on **Use Tailscale DNS settings**, then set the exit node again and test `curl ifconfig.me`.

5. **Try exit node by Tailnet IP**  
   If the hostname does not work, use the VPS Tailnet IP:  
   `tailscale set --exit-node=100.64.0.1`  
   (Replace with your VPS Tailnet IP from `tailscale status`.) Then run `curl ifconfig.me`.

6. **ACL**  
   If you use a Headscale ACL policy, it must allow the laptop to reach the exit node and the internet (e.g. `autogroup:internet` or explicit allow to the VPS). With policy mode "database" and no custom ACL, default is allow-all.

7. **Reconnect**  
   After approving on Headscale (or changing DNS), disconnect and reconnect Tailscale on the laptop (or run `tailscale set --exit-node=vps` again), then test `curl ifconfig.me`.

---

## 7. Enable VPN-only Argo CD (Traefik middleware)

The repo already includes:
- A Traefik **Middleware** `argocd-vpn-only` that allows only `100.64.0.0/10` (Tailnet).
- An **annotation** on the Argo CD server Ingress that uses this middleware.

After the Argo CD app is synced:
- From a **non-VPN** network, open `https://argocd.tukangketik.net` — you should get **403 Forbidden** (or 404).
- From a **VPN-connected** device (phone or laptop), open `https://argocd.tukangketik.net` — the Argo CD UI should load and Authentik SSO should work as before.

---

## 8. Break-glass: regain Argo CD access if locked out

If you cannot reach Argo CD (e.g. VPN down and middleware blocks public access):

1. **SSH to the VPS** (port 22 is still open).
2. **Temporarily disable the VPN-only middleware** so Argo CD is reachable from the internet again:
   - In `deploy/argocd/apps/argocd/values.yaml`, remove or comment out the line:
     ```yaml
     traefik.ingress.kubernetes.io/router.middlewares: argocd-argocd-vpn-only@kubernetescrd
     ```
   - Commit, push, and sync the Argo CD app (or apply the Ingress change manually with `kubectl`).
3. Log in to Argo CD, fix VPN/DNS, then re-add the middleware line and sync again.

---

## 9. Rotating pre-auth keys (reset and use a new key)

To stop using the old auth key and connect with a new one on a device (e.g. VPS):

1. **Create a new pre-auth key** (from a machine that can run Headscale CLI):
   ```bash
   kubectl exec -n headscale deploy/headscale -- headscale preauthkeys create --user fakhrur --reusable --tag vps --expiration 87600h --output
   ```
   Save the printed key.

2. **On the device (e.g. VPS):** Log out so the client drops the current session and forgets the old key:
   ```bash
   sudo tailscale logout
   ```
   (Or `sudo tailscale down` if your client has no `logout`; then the next `up` will re-register.)

3. **On the device:** Connect using the new key:
   ```bash
   sudo tailscale up \
     --login-server=https://headscale.tukangketik.net \
     --accept-dns=false \
     --authkey=NEW_KEY \
     --hostname=vps
   ```
   Replace `NEW_KEY` with the key from step 1. Use `--accept-dns=true` on laptop/phone if you use Tailscale DNS there.

4. **Optional:** In Headscale, delete the old node if it still appears (so the hostname is free for the new registration):  
   `kubectl exec -n headscale deploy/headscale -- headscale nodes list` then `headscale nodes delete -i <id>` for the old “vps” node. If you don’t delete it, the new login may reuse the same node or create a second one depending on client behaviour.

You can expire or revoke old keys in Headscale via the API/CLI or Headplane UI if desired.

---

## 10. Reference

| Item | Value |
|------|--------|
| Headscale URL | `https://headscale.tukangketik.net` |
| Headplane URL | `https://headplane.tukangketik.net` |
| MagicDNS base | `vpn.tukangketik.net` |
| Argo CD (VPN-only) | `https://argocd.tukangketik.net` |
| Tailnet IP range | `100.64.0.0/10` |
| Firewall: Tailscale WireGuard | UDP 41641 |
| Firewall: Headscale DERP | UDP 3478 |
| Argo CD VPN allowlist | Traefik middleware `argocd-vpn-only` (100.64.0.0/10) |
| Headscale SSO | [headscale-authentik-sso.md](headscale-authentik-sso.md) |
| Headplane SSO | [headplane-authentik-sso.md](headplane-authentik-sso.md) |
| VPN-only internal apps | [vpn-only-apps.md](vpn-only-apps.md) |

---

## 11. Headplane Web UI

[Headplane](https://headplane.net) is a web UI for Headscale (nodes, ACLs, DNS). It is deployed as a separate Argo CD app.

1. **DNS:** Add an A record for `headplane.tukangketik.net` pointing to your VPS (same as Headscale).
2. **Sync:** In Argo CD, sync the **headplane** application (namespace `headplane`). Wait for the Deployment and certificate.
3. **Create the secret** (not in Git — required before Headplane can start): create `headplane-secrets` with at least `cookie_secret` (32 chars); for OIDC also add `oidc_client_secret` and `headscale_api_key`. See [Headplane Authentik SSO](headplane-authentik-sso.md) for the full `kubectl create secret generic ...` command. Then restart: `kubectl rollout restart deployment/headplane -n headplane`
4. **Log in:** Open `https://headplane.tukangketik.net` (or `/admin`). Log in with a **Headscale API key** (create one with `headscale apikeys create --expiration 999d` inside the Headscale pod).
5. **Optional – OIDC (Authentik):** Headplane is preconfigured for Authentik using the **same** provider as Headscale. See [Headplane Authentik SSO](headplane-authentik-sso.md): add redirect URI `https://headplane.tukangketik.net/admin/oidc/callback` to the Headscale provider in Authentik, set `oidc.client_id` in the Headplane ConfigMap to match Headscale, and set `oidc_client_secret` and `headscale_api_key` in the `headplane-secrets` Secret.

---

## 12. ACL policy (database mode)

Headscale is configured with **policy mode: database** (`HEADSCALE_POLICY_MODE: "database"`). This is supported in both 0.27.1 and 0.28.x. ACLs are stored in the Headscale database, not in a file. You manage them via:

- **Headplane UI:** `https://headplane.tukangketik.net` → ACL / Policy (edit and save).
- **Headscale API:** `POST /api/v1/policy` with a Bearer token (API key). Create a key with `headscale apikeys create --expiration 999d` inside the Headscale pod.

**Example policy** (allow all tailnet members to reach `tag:vps` on 443 and 22; adjust `group:admins` and `tag:vps` as needed). Use this in Headplane or as the body of `POST /api/v1/policy`:

```json
{
  "groups": {
    "group:admins": ["president@"]
  },
  "tagOwners": {
    "tag:vps": ["group:admins"]
  },
  "acls": [
    {
      "action": "accept",
      "src": ["autogroup:member"],
      "dst": ["tag:vps:443", "tag:vps:22"]
    }
  ]
}
```

After switching from file to database mode (e.g. you were on 0.28 with file mode and are now on 0.27.1 with database mode), the policy was never stored in the DB—set it **once** via Headplane or the API so your tailnet has the same rules as before.

---

## 13. Headscale version and database migration

We run **Headscale 0.27.1** because Headplane 0.6.1 does not support Headscale 0.28.x.

**“Invalid schema” with 0.28:** If you previously tried 0.28.0, it may fail at startup with `init database: validating schema: invalid schema` (e.g. `nodes` / `pre_auth_keys` column differences). 0.28 uses a different schema and does not support direct upgrades from older DBs in some cases.

**Fix (what we did):** Stay on **0.27.1**. Your existing SQLite DB (created by 0.26/0.27) is compatible with 0.27.1; no migration is required. After changing the image tag to `v0.27.1` and syncing, Headscale should start normally.

**If 0.28 already ran once:** If 0.28 modified the database before you downgraded, 0.27.1 might then complain about the newer schema. In that case:
1. Restore the SQLite DB from a backup taken before the 0.28 run (e.g. from the Headscale PVC or a copy of `db.sqlite`).
2. Or start with a fresh DB (re-create users and pre-auth keys, re-join nodes) if you have no backup.

**When upgrading to 0.28 later** (after Headplane supports it):
1. Back up the DB: copy `/var/lib/headscale/db.sqlite` from the pod or PVC.
2. Upgrade the image to `v0.28.0` and sync. Headscale 0.28 may run migrations on startup; if you still see “validating schema” and it refuses to start, Headscale’s docs require a sequential upgrade path (e.g. 0.25 → 0.26 → 0.27 → 0.28) for very old DBs.
3. If all else fails, restore the backup and stay on 0.27.1 until you can do a clean upgrade or recreate the tailnet.

---

## 14. Troubleshooting: "fetch control key: context canceled"

When logging in (e.g. with a new auth key), Tailscale may report:

```text
fetch control key: Get "https://headscale.tukangketik.net/key?v=131": context canceled
```

**"Context canceled"** means the request to your Headscale server was aborted before completing. Common causes:

1. **Network / firewall**  
   From the same machine where login fails, check reachability:
   ```bash
   curl -v --connect-timeout 10 "https://headscale.tukangketik.net/key?v=131"
   ```
   - If this hangs or fails (connection refused, timeout, TLS error), fix network/firewall/DNS or try another network (e.g. mobile hotspot).
   - You may get `401 Unauthorized` or similar from Headscale — that’s OK; it means the request reached the server.

2. **Timeout (client or proxy)**  
   The Tailscale client has its own timeout; if the server or path is slow, the client can cancel. Options:
   - Retry from a faster network.
   - Ensure the Headscale pod is healthy and not overloaded: `kubectl get pods -n headscale`, check logs.
   - Optionally increase Traefik backend timeouts for Headscale (see `deploy/argocd/apps/headscale/manifests/headscale-serverstransport.yaml` and the IngressRoute’s `serversTransport`).

3. **TLS / certificate**  
   Ensure the certificate for `headscale.tukangketik.net` is valid and trusted (e.g. `openssl s_client -connect headscale.tukangketik.net:443 -servername headscale.tukangketik.net`). Wrong cert or SNI can cause connection drops that show up as "context canceled".

4. **Tailscale version**  
   Older Tailscale versions had control-plane timeout bugs. Update the client (e.g. `tailscale version`) and try again.

5. **Proxy / VPN**  
   If the machine is behind an HTTP proxy or another VPN that intercepts HTTPS, it can break the request. Try without that proxy/VPN or from a different network.

---

## 15. Troubleshooting: VPS cannot access anything

If the VPS suddenly **cannot reach anything** (SSH, HTTPS, apt, etc.) after a Tailscale login failure or logout, the usual cause is **DNS**.

The VPS was likely brought up with `--accept-dns=true`. Tailscale then set the system DNS to **MagicDNS** (100.100.100.100). When Tailscale is logged out or broken, that DNS server no longer responds, so the VPS fails to resolve any hostname and appears to have no connectivity (ping by IP may still work).

**Recovery (use the provider’s out-of-band console if SSH is unreachable):**

1. **Restore working DNS** so the VPS can resolve names again:
   ```bash
   # Option A: Bring Tailscale down; on some setups this restores previous resolv.conf
   sudo tailscale down

   # Option B: Overwrite DNS with a working resolver (do this if Option A doesn’t fix it)
   echo "nameserver 8.8.8.8" | sudo tee /etc/resolv.conf
   # or use your provider’s resolver, e.g. 1.1.1.1
   ```
2. Confirm: `ping -c1 8.8.8.8` and `ping -c1 google.com` (or any hostname). If the latter works, DNS is fixed.
3. Either **log Tailscale back in** with a working auth key (so the VPS is on the tailnet again), or leave Tailscale down and keep using the manual DNS above.

**Avoid this next time (VPS-only):** The VPS does not need Tailscale to resolve names for its own outbound traffic. Use `--accept-dns=false` when connecting the VPS so the host keeps using normal DNS and stays reachable even when Tailscale is down:

```bash
sudo tailscale up \
  --login-server=https://headscale.tukangketik.net \
  --accept-dns=false \
  --authkey=YOUR_VPS_PREAUTH_KEY \
  --hostname=vps
```

Laptops and phones should keep **Use Tailscale DNS** (or `--accept-dns=true`) so MagicDNS and the `argocd.tukangketik.net` extra record work.

---

## 16. Troubleshooting: Laptop not using Tailscale DNS (system still shows 10.0.14.1, etc.)

If `tailscale dns status` shows **Tailscale DNS: enabled** and **Resolvers** from the server (e.g. 100.100.100.100 or 94.140.x.x), but **System DNS configuration** still lists your router/local resolvers (e.g. 10.0.14.1, 1.1.1.1), the OS is not actually using the Tailscale-provided resolvers for all traffic. That can happen when the Tailscale client does not fully override system DNS (common on macOS with Headscale).

**What to do:**

1. **macOS**
   - In the **Tailscale menu** (menu bar) → **Settings** (or **Preferences**): ensure **Use Tailscale DNS settings** is checked.
   - If you see **Override local DNS**, turn it **on** so the system uses Tailscale’s resolvers instead of the current system DNS.
   - Disconnect and reconnect Tailscale (or turn the VPN off and on), then run `tailscale dns status` again. If the system still shows 10.x.x.x, macOS may be limiting what the app can change; split DNS for `tukangketik.net` can still work because the client intercepts those queries.
   - **Check that split DNS works:**  
     `dscacheutil -q host -a name argocd.tukangketik.net`  
     If the IP is the Tailnet IP (100.64.x.y), Tailscale DNS is working for your tailnet domains even if “System DNS configuration” doesn’t update.

2. **Linux**
   - Force acceptance of Tailscale DNS: `tailscale set --accept-dns=true`.
   - Ensure the client can change system DNS: if you use **systemd-resolved**, Tailscale typically integrates with it; if you use `/etc/resolv.conf` directly, ensure nothing (e.g. NetworkManager) is overwriting it after Tailscale sets it. Restart tailscaled if needed: `sudo systemctl restart tailscaled`, then `tailscale up` again.

3. **Server-side (already set in this repo)**  
   Headscale has `HEADSCALE_DNS_OVERRIDE_LOCAL_DNS: "true"`, so the server is telling the client to override local DNS. If the system still doesn’t switch, the limitation is on the client/OS side (especially macOS).

**Summary:** If “System DNS configuration” never changes but `argocd.tukangketik.net` (and other `*.tukangketik.net`) resolve to the Tailnet IP, split DNS is working. For **all** traffic to use Tailscale’s global resolvers, enable **Override local DNS** on the client (macOS app or equivalent) and ensure the client can manage system DNS (Linux).

---

## 17. Troubleshooting: Phone on VPN but Argo CD returns 403 Forbidden

Argo CD is restricted to **Tailnet IPs** (100.64.0.0/10) only. For the request to be allowed, the phone must **reach** `argocd.tukangketik.net` **over the VPN** — i.e. the domain must resolve to the **Tailnet IP** (e.g. 100.64.0.1), not the public IP, so the connection goes through Tailscale and Traefik sees the phone's Tailnet IP.

**Fix: enable Use Tailscale DNS on the phone**

1. Open the **Tailscale** app on the phone.
2. Go to **Settings** (or the gear icon).
3. Turn **on** **Use Tailscale DNS** (or **Custom DNS** / **MagicDNS** — the option that makes the device use Tailscale for DNS).
4. Fully close the browser (or clear its cache), then open `https://argocd.tukangketik.net` again.

With Tailscale DNS on, the phone will resolve `argocd.tukangketik.net` via Headscale and get the extra record (Tailnet IP). The connection will go over the VPN and the middleware will allow it.

---

## 18. Troubleshooting: headscale.tukangketik.net returns 404

If the domain suddenly returns **404**:

1. **Check the backend Service name.** Run `kubectl get svc -n headscale`. The IngressRoute must use that exact name (e.g. `headscale`). The manifest is at `deploy/argocd/apps/headscale/manifests/headscale-ingressroute.yaml` and should have `name: headscale` to match the Service.

2. **Check Headscale pod and endpoints.** If the pod is crashlooping or not ready, there are no endpoints and Traefik may return 503 (or 404 in some setups). Run:
   ```bash
   kubectl get pods -n headscale
   kubectl get endpoints -n headscale
   ```

3. **Confirm the IngressRoute is loaded.** `kubectl get ingressroute -n headscale` and check Traefik logs if the route exists but traffic still fails.

**Cannot reach Argo CD when using the Tailnet IP (100.64.0.1):**  
On the VPS, Traefik (the ingress) is exposed by k3s as a LoadBalancer that typically listens only on the node’s **primary (public) IP**, not on the Tailscale IP. So when you point `argocd.tukangketik.net` to a Tailnet IP and connect, the connection reaches the VPS on the Tailscale interface but nothing is listening on that IP:443 — hence “cannot reach”.

**Fix (recommended):** Use the **incluster-vpn** proxy ([vpn-only-apps.md](vpn-only-apps.md)). It joins the tailnet and reverse-proxies `argocd.tukangketik.net` to Argo CD. In `deploy/argocd/apps/tailscale-dns/manifests/configmap.yaml` (under `tukangketik.hosts`), set `argocd.tukangketik.net` to the **incluster-vpn** pod Tailnet IP (not the VPS Tailnet IP).

**argocd.tukangketik.net resolves to public IP instead of Tailnet IP:** The client must use the custom DNS (100.64.0.1) or MagicDNS so that domain resolves to the Tailnet IP. Ensure the laptop has **Use Tailscale DNS** (and optionally **Override local DNS**) enabled so Headscale sends 100.64.0.1 as the resolver. If it still resolves to the public IP, fix DNS on the client (see §5.1).

---

## 19. Troubleshooting: Cannot access Argo CD with Tailscale up (middleware and ingress in place)

If the VPN-only middleware and ingress are in place but Argo CD still does not load when you connect with Tailscale:

**1. Client must resolve argocd.tukangketik.net to 100.64.0.1**

On the device where you open the browser (laptop/phone):

- **macOS/Linux:** `nslookup argocd.tukangketik.net` or `getent hosts argocd.tukangketik.net`
- **Expected:** `100.64.0.1` (or your VPS Tailnet IP). If you see the public IP (e.g. 135.x.x.x), the middleware will see your public/external source and return **403**.

**Fix:** Enable **Use Tailscale DNS** (and optionally **Override local DNS**) in the Tailscale client so the device uses Headscale’s resolver (100.64.0.1) and gets the Tailnet A record.

**2. iptables forward must be active on the VPS (DNS only)**

On the VPS (SSH):

```bash
sudo iptables -t nat -L PREROUTING -n -v | grep 100.64.0.1
sudo iptables -t nat -L OUTPUT -n -v | grep 100.64.0.1
```

You should see rules for **port 53** (DNS). If not, run the forward script and persist:

```bash
sudo bash /path/to/vps-setup/09-argocd-tailscale-ip-forward.sh
sudo netfilter-persistent save   # or iptables-persistent
```

**3. Direct test from the client (on VPN)**

From the same device (Tailscale on):

```bash
curl -v -k --connect-timeout 10 https://100.64.0.1 -H "Host: argocd.tukangketik.net"
```

- **Hangs at “Trying 100.64.0.1”:** iptables forward not applied or not taking effect (re-run script, check OUTPUT rules if testing from VPS).
- **403 Forbidden:** The request is not seen as coming from a Tailnet IP (e.g. SNAT). Do not allowlist the k3s pod CIDR — that can make Argo CD publicly reachable. Use the **incluster-vpn** proxy and point DNS to its pod Tailnet IP ([vpn-only-apps.md](vpn-only-apps.md)).
- **Connection refused:** Often caused by TAILNET_DNAT using `127.0.0.1` instead of the public IP. Check: `sudo iptables -t nat -L TAILNET_DNAT -n -v`. The DNAT target must be your VPS public IP (e.g. `135.125.131.209`), not `127.0.0.1`. Re-run `sudo bash vps-setup/09-argocd-tailscale-ip-forward.sh` and persist.

**4. Confirm middleware name and namespace**

Traefik expects the middleware as `namespace-name` in the annotation, e.g. `argocd-argocd-vpn-only@kubernetescrd` = namespace `argocd`, name `argocd-vpn-only`. On the VPS:

```bash
kubectl get middleware -n argocd
kubectl get ingress -n argocd -o yaml | grep -A2 middlewares
```

**5. Traefik logs**

On the VPS:

```bash
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=100
```

Look for 403 or errors mentioning argocd or the middleware.
