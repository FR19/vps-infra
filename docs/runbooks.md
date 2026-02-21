# Runbooks

Operational procedures for platform infrastructure. Use these when something fails or when performing maintenance.

## Table of contents

- [Emergency procedures](#emergency-procedures) (includes [Multus CrashLoopBackOff](#multus-crashloopbackoff--cannot-access-argocd-authentik-etc) and [Too many open files / fsnotify](#too-many-open-files--fsnotify-watcher))
- [Authentik](#authentik)
- [Argo CD](#argocd) (includes [Upgrade Argo CD](#upgrade-argocd-chart--app-version) and [Upgrade Helm used by Argo CD](#upgrade-helm-used-by-argocd))
- [Mailu](#mailu)
- [Backup & restore](#backup--restore)
- [Security incidents](#security-incidents)
- [Maintenance](#maintenance)

**Quick links:** [Fix Argo CD in place](deployment-infra.md#update-argocd-config-in-place) · [Teardown only Argo CD](deployment-infra.md#teardown-only-argocd) · [Full teardown](deployment-infra.md#teardown-full)

---

## Emergency procedures

### Service down

**Symptoms:** Services not responding, 502/503 errors.

```bash
kubectl get nodes
kubectl get pods --all-namespaces
kubectl get ingress --all-namespaces
kubectl get certificates --all-namespaces
kubectl top nodes
kubectl top pods --all-namespaces
```

**Actions:** Restart stuck pods (`kubectl delete pod -n <ns> <pod>`), scale deployments if needed, check Ingress and Certificate resources.

### Multus CrashLoopBackOff – cannot access Argo CD, Authentik, etc.

**Symptoms:** `kube-multus-ds-*` in `kube-system` is CrashLoopBackOff; cluster or apps (Argo CD, Authentik) become unreachable.

**Cause:** Multus (e.g. for VPN or secondary networks) on K3s often uses wrong paths or hits a race and crashes, which can affect networking.

**Immediate recovery – remove Multus** (restores cluster; reinstall later if you need Multus again):

```bash
# Remove the Multus DaemonSet and its pods (from the standard manifest URL)
kubectl delete daemonset -n kube-system kube-multus-ds
# If the manifest created different resource names, list and delete:
kubectl get daemonset -n kube-system | grep multus
kubectl delete daemonset -n kube-system <name>
```

Wait a minute, then check core pods and try accessing Argo CD / Authentik again. If things are still broken, restart the K3s service on the node: `sudo systemctl restart k3s` (or `k3s agent` if applicable).

**Reinstalling Multus (K3s):** The upstream manifest uses `/etc/cni/net.d` and `/opt/cni/bin`; K3s often uses `/var/lib/rancher/k3s/agent/etc/cni/net.d` and a data dir for binaries. See [K3s Multus](https://docs.k3s.io/networking/multus-ipams) and [Multus on K3s](https://gist.github.com/janeczku/ab5139791f28bfba1e0e03cfc2963ecf); use a K3s-adapted manifest or set the daemonset’s host paths to match your node (`ls /var/lib/rancher/k3s/agent/etc/cni/net.d` and kubelet’s cni-conf-dir).

**Multus OOMKilled:** If the pod is killed for OOM (check `kubectl get pod -n kube-system <multus-pod> -o jsonpath='{.status.containerStatuses[0].lastState.terminated.reason}'`), increase memory: edit the DaemonSet and set `resources.limits.memory` (e.g. `200Mi`) and `resources.requests.memory` (e.g. `100Mi`) for the `kube-multus` container. **Source of truth:** Use the repo manifest [deploy/multus/multus-daemonset.yaml](deploy/multus/multus-daemonset.yaml), which already sets 100Mi request / 200Mi limit. Apply with `kubectl apply -f deploy/multus/multus-daemonset.yaml` (after removing the existing Multus objects if reinstalling).

### Authentication failure

**Symptoms:** Users cannot log in, 401 errors.

```bash
kubectl get pods -n auth
kubectl logs -n auth deployment/authentik
kubectl get ingress -n auth
curl -sI https://auth.<your-domain>
curl -s https://auth.<your-domain>/application/o/vps-platform/jwks/
```

**Actions:** Restart Authentik if needed (`kubectl rollout restart -n auth deployment/authentik`). In Authentik UI, verify provider, applications, and client IDs.

### Too many open files / fsnotify watcher

**Symptoms:** Logs or system messages: `failed to create fsnotify watcher: too many open files`, or processes (K3s, Argo CD, Traefik, etc.) failing with inotify or file-descriptor limits. **If you see this when running `kubectl logs -f` on Traefik (or another pod), the error is from the process inside the pod on the VPS**, not from your local machine—Traefik (or the node) hit the limit.

**Cause:** The **node (VPS)** hit the limit on inotify watches (`fs.inotify.max_user_watches` / `fs.inotify.max_user_instances`) or on open file descriptors. Containers share the host’s limits. Common on a busy VPS running K3s with many pods and controllers (Argo CD, cert-manager, Traefik, etc.) that watch many paths.

**Immediate fix – raise inotify limits (persistent):**

```bash
# On the VPS (root or sudo). Creates/overwrites the file so safe to run once.
sudo tee /etc/sysctl.d/99-inotify.conf << 'EOF'
fs.inotify.max_user_watches=524288
fs.inotify.max_user_instances=8192
EOF
sudo sysctl -p /etc/sysctl.d/99-inotify.conf
```

**Optional – raise open-file limits for K3s** (if the error comes from the K3s service):

```bash
# For K3s via systemd (default)
sudo mkdir -p /etc/systemd/system/k3s.service.d
echo -e '[Service]\nLimitNOFILE=65536' | sudo tee /etc/systemd/system/k3s.service.d/limits.conf
sudo systemctl daemon-reload
sudo systemctl restart k3s
```

**Check current limits:**

```bash
sysctl fs.inotify.max_user_watches fs.inotify.max_user_instances
# Per-process (e.g. for PID of k3s)
cat /proc/$(pgrep -f 'k3s server' | head -1)/limits 2>/dev/null | grep 'open files'
```

After applying the sysctl on the **VPS**, restart the failing process: if the error was in Traefik logs, restart the Traefik pod so it runs under the new limits (`kubectl delete pod -n kube-system -l app.kubernetes.io/name=traefik` or the appropriate label/name for your install). For K3s itself, `sudo systemctl restart k3s`.

**If the error appears when you run `kubectl logs -f` (e.g. to watch Traefik or another pod):** You don't need to follow. Trigger the failing action, then as soon as the error appears run a **one-off** (no `-f`) to capture recent logs, e.g. `kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=100`. To allow `-f` in the current shell: `ulimit -n 65536` then run `kubectl logs ... -f` in that same shell.

---

## Authentik

### Unhealthy / startup probe failed / "Secret key missing"

**Symptoms:** Authentik server pods fail startup; logs show "Secret key missing" or "no password supplied" (Postgres).

**Cause:** Required one-time Secrets are missing: `authentik-secret-key` (cookie signing) and `authentik-postgresql` (DB password for the PostgreSQL subchart).

**Resolution:**

```bash
./scripts/create-auth-secret.sh
./scripts/create-auth-db-secret.sh
kubectl rollout restart deployment -n auth -l app.kubernetes.io/name=authentik
```

### PostgreSQL password authentication failed

**Symptoms:** Authentik server or worker logs: "password authentication failed" or "no password supplied" when connecting to PostgreSQL.

**Cause:** PostgreSQL was created before the `authentik-postgresql` Secret existed (or with a different password). The database was initialized with another password; Authentik is using the Secret, so they do not match.

**Resolution:** Recreate PostgreSQL so it initializes with the Secret password. This **wipes Authentik's database** (acceptable for a fresh install).

1. Ensure the Secret exists: `./scripts/create-auth-db-secret.sh`
2. Run: `./scripts/recreate-auth-postgres.sh`

The script scales down Postgres, deletes the PostgreSQL PVC, scales back up so the new pod initializes the DB with the Secret password, then restarts Authentik server/worker.

### PostgreSQL/Redis pods not recreated after value change

**Symptoms:** You changed values (e.g. `postgresql.image.tag`, `redis.image.tag`) and synced the Authentik app, but the Postgres/Redis pods were not recreated.

**Cause:** Helm may not trigger a rollout when only a subchart image tag changes, or the sync did not update the in-cluster manifest.

**Resolution:** Force a rollout:

```bash
kubectl rollout restart statefulset authentik-postgresql -n auth
kubectl rollout restart statefulset authentik-redis-master -n auth
# If names differ: kubectl get statefulset -n auth
```

### Cosmetic OutOfSync (StatefulSet creationTimestamp)

**Symptoms:** The Authentik Application shows **OutOfSync** with a diff on StatefulSets `authentik-postgresql` and `authentik-redis-master` (e.g. `metadata.creationTimestamp`: `null` in desired vs timestamp in live).

**Cause:** Helm templates emit `creationTimestamp: null`; the API server sets the real timestamp on create. Argo CD diff treats this as a difference.

**Resolution:** Treat as **cosmetic**. The app is healthy. Do **not** sync to "fix" the diff; syncing can trigger unnecessary replaces. Leaving the Application OutOfSync for this reason is safe.

---

## Argo CD

### 404 when accessing by domain

**Symptoms:** `https://argocd.<domain>` returns 404. Port-forward works (e.g. `kubectl port-forward svc/argocd-server -n argocd 8080:80` then `http://localhost:8080`).

**Diagnosis:**

```bash
kubectl get ingress -n argocd
kubectl get ingress -n argocd -o yaml | grep -A5 "host:\|hostname:"
kubectl get svc,endpoints -n argocd argocd-server
kubectl get ingress -n argocd -o yaml | grep -A2 ingressClassName
kubectl get ingressclass
kubectl logs -n kube-system -l app.kubernetes.io/name=traefik --tail=50 | grep -i argocd
nslookup argocd.<your-domain>
curl -v https://argocd.<your-domain>
```

**Resolutions:**

1. **No Ingress:** If `kubectl get ingress -n argocd` is empty, the Helm release did not create it. From repo root:
   ```bash
   helm dependency update deploy/argocd/helm
   helm upgrade --install argocd deploy/argocd/helm -n argocd -f deploy/argocd/helm/values.yaml
   ```
   Then confirm: `kubectl get ingress -n argocd` shows the correct host.

2. **Ingress class:** Values must set `ingressClassName: traefik` so k3s Traefik uses this Ingress. If the cluster has no `traefik` IngressClass, list with `kubectl get ingressclass` and either create it or set `ingressClassName: ""` in the Ingress so Traefik uses the default.

3. **Hostname mismatch:** Ensure the Ingress `host` matches the DNS name exactly (no typos).

4. **No endpoints:** If `argocd-server` has no endpoints, the server pods are not ready. Check: `kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-server`.

5. **Traefik entrypoint:** Ingress uses `websecure` (HTTPS). Confirm Traefik has that entrypoint: `kubectl get configmap -n kube-system traefik -o yaml | grep -i entrypoint`. If only `web` exists, adjust the Ingress annotation or Traefik config.

### 502 and TLS / backend / certificate issues

**Symptoms:** 502 Bad Gateway, or site loads but browser shows "Not secure", or Traefik logs "secret argocd-server-tls does not exist".

**Diagnosis:**

```bash
kubectl get certificate -n argocd
kubectl describe certificate -n argocd
kubectl get secret -n argocd argocd-server-tls
kubectl get ingress -n argocd -o yaml | grep -A10 annotations
kubectl get deployment argocd-server -n argocd -o yaml | grep -A5 "args:"
```

**Resolutions:**

1. **TLS secret missing:** Certificate must be Ready before the secret exists. Check `kubectl get certificate,order,challenge -n argocd`. For HTTP-01, ensure the Argo CD hostname resolves to the VPS and port 80 is reachable. Check cert-manager logs: `kubectl logs -n cert-manager -l app=cert-manager`. Optional: `./scripts/diagnose-argocd-tls.sh`.

2. **Staging certificate (browser "Not secure"):** If the Certificate was issued by `letsencrypt-staging`, browsers will not trust it. Switch to production:
   ```bash
   kubectl delete certificate -n argocd argocd-server-tls
   kubectl delete secret -n argocd argocd-server-tls
   ```
   Ensure the Ingress (or chart values) uses `cert-manager.io/cluster-issuer: letsencrypt-prod`. Re-sync the argocd Application or wait for cert-manager to re-issue. When the Certificate is Ready and the secret exists, reload in a private/incognito window to avoid cached cert state.

3. **Certificate is prod and Ready but browser still "Not secure":** Confirm in the browser (DevTools → Security / padlock) that the certificate is from Let's Encrypt and the domain matches. If so, try a private window or another browser (often cached from staging). Confirm the Ingress uses `secretName: argocd-server-tls`.

4. **502 with TLS / backend:** Ensure (a) Ingress has the `traefik.ingress.kubernetes.io/service.serversscheme: http` annotation, (b) Argo CD server deployment has `args: ["--insecure"]`. If `--insecure` is missing:
   ```bash
   kubectl patch deployment argocd-server -n argocd --type=json -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--insecure"}]'
   # If that fails (path exists): use "replace" or ensure args array exists first
   kubectl rollout restart deployment argocd-server -n argocd
   ```

5. **Ingress backend port reverts to 443:** The **argocd** Application syncs the chart from Git. If Git has backend port 443 (no `configs.params.server.insecure`), each sync overwrites a local fix. **Fix:** Set `configs.params.server.insecure: "true"` in `deploy/argocd/helm/values.yaml` in the repo, push, then Hard Refresh and Sync the **argocd** app so the cluster state comes from Git.

### HTTP → HTTPS redirect

The Argo CD wrapper chart deploys a Traefik `Middleware` (redirect-https) and an `IngressRoute` that redirects HTTP to HTTPS for all hosts on port 80. New subdomains get the same behavior; no per-domain config is required.

### RBAC – permission denied for app

**Symptoms:** CLI returns `PermissionDenied` for apps in the `vps-platform` project (e.g. `argocd app get argocd`).

**Cause:** RBAC default role or policy for the project is not set.

**Resolution:** The Git-managed values in `deploy/argocd/helm/values.yaml` set `policy.default: role:admin` and a rule for `vps-platform/*`. After the **argocd** Application syncs, this applies. To fix immediately:

```bash
kubectl -n argocd patch configmap argocd-rbac-cm --type merge -p '{"data":{"policy.csv":"p, role:admin, applications, *, vps-platform/*, allow\n","policy.default":"role:admin"}}'
kubectl -n argocd rollout restart deployment argocd-server
```

Then retry `argocd app get argocd` (or `argocd app sync argocd`).

### Upgrade Argo CD (chart / app version)

The repo pins the **argo-cd** Helm chart to a specific version in `deploy/argocd/apps/argocd/Chart.yaml` (e.g. **9.4.3** → Argo CD app **3.3.1**). To move to a newer stable release:

1. In `deploy/argocd/apps/argocd/Chart.yaml`, set the `argo-cd` dependency `version` (and optionally `appVersion`) to the desired chart/app version.
2. From the chart directory: `helm dependency update`, then commit `Chart.yaml` and `Chart.lock`, push, and sync the **argocd** Application.

**Upgrading from Argo CD 2.x to 3.x:** Follow the official [2.14 → 3.0 upgrade guide](https://argo-cd.readthedocs.io/en/latest/operator-manual/upgrading/2.14-3.0/). Notable changes: fine-grained RBAC for applications (optional `server.rbac.disableApplicationFineGrainedRBACInheritance`), logs RBAC (add `logs, get` to policy if needed), and project API response sanitization.

### Upgrade Helm used by Argo CD

**Why:** Argo CD’s repo-server ships with a bundled Helm version. That version can cause errors (e.g. `invalid_reference: invalid tag` when using the Bitnami HTTPS chart repo with Helm 3.16.3/3.16.4). Using Bitnami charts via **OCI** (e.g. `oci://registry-1.docker.io/bitnamicharts`) avoids the bug; if you need the HTTPS repo or a specific Helm feature, you can upgrade Helm instead.

**Option A – Upgrade Argo CD**

Newer Argo CD releases bundle a newer Helm. Upgrade the Argo CD Helm chart (and image) so the repo-server gets a newer bundled Helm:

1. In `deploy/argocd/apps/argocd/Chart.yaml`, bump the `argo-cd` dependency version (e.g. the repo is on **9.4.3**; see [argo-helm releases](https://github.com/argoproj/argo-helm/releases)).
2. Run `helm dependency update` in the chart directory, commit `Chart.yaml` and `Chart.lock`, push, and sync the **argocd** app.
3. Check the [Argo CD changelog](https://github.com/argoproj/argo-cd/blob/master/CHANGELOG.md) or release notes for the Helm version bundled with that release.

**Option B – Override Helm with an init container**

Keep your current Argo CD version and replace the repo-server’s Helm binary with Helm 3.17+ via an init container and volume mount:

1. In `deploy/argocd/apps/argocd/values.yaml`, under `argo-cd.repoServer`, add a volume, an init container that downloads Helm, and a volume mount on the repo-server container.

2. Example (adjust the Helm version URL if needed; use a version ≥ 3.17.0):

```yaml
# Under argo-cd.repoServer in deploy/argocd/apps/argocd/values.yaml
repoServer:
  volumes:
    - name: custom-tools
      emptyDir: {}
  initContainers:
    - name: download-helm
      image: alpine:3.19
      command: [sh, -c]
      args:
        - |
          set -e
          apk add --no-cache wget tar
          wget -qO- https://get.helm.sh/helm-v3.17.0-linux-amd64.tar.gz | tar -xzvf - -C /custom-tools --strip-components=1 linux-amd64/helm
      volumeMounts:
        - name: custom-tools
          mountPath: /custom-tools
  volumeMounts:
    - name: custom-tools
      mountPath: /usr/local/bin/helm
      subPath: helm
```

3. Commit, push, and sync the **argocd** app. Restart the repo-server if needed: `kubectl rollout restart deployment argocd-repo-server -n argocd`.

4. **ARM64 / non-amd64:** Use the matching Helm tarball (e.g. `linux-arm64`) and adjust the `args` path (e.g. `arm64/helm`).

Reference: [Argo CD – Custom tooling](https://argo-cd.readthedocs.io/en/stable/operator-manual/custom_tools/).

---

## Mailu

### 502 Bad Gateway (mail.tukangketik.net)

**Symptoms:** Visiting https://mail.tukangketik.net returns 502 Bad Gateway. Traefik and mailu-front logs show no errors.

**Causes and fixes:**

1. **Backend scheme:** Traefik must talk to the Mailu front over HTTP (TLS is terminated at Traefik). Ensure the Ingress has:
   - `traefik.ingress.kubernetes.io/service.serversscheme: http` (value **lowercase** `http`).
   - `traefik.ingress.kubernetes.io/router.entrypoints: websecure` so HTTPS traffic is routed.

2. **Verify backend has endpoints:**
   ```bash
   kubectl get svc -n mailu
   kubectl get endpoints -n mailu
   kubectl get pods -n mailu -l app.kubernetes.io/component=front
   ```
   If the Service used by the Ingress has 0 endpoints, fix the front deployment/readiness before expecting the Ingress to work.

3. **Backend port:** The Mailu front serves HTTP on port 80 when `TLS_FLAVOR=notls`. If the chart’s Ingress backend port is 443, Traefik will get a wrong response and may return 502. Check the generated Ingress:
   ```bash
   kubectl get ingress -n mailu -o yaml
   ```
   The `backend.service.port.number` (or equivalent) should be 80 for HTTP.

4. **Re-sync after values change:** After changing `deploy/argocd/apps/mailu/values.yaml` (e.g. annotations), push to Git and in Argo CD run **Hard Refresh** and **Sync** for the **mailu** Application.

### Mailu + Authentik: infinite redirect after login

**Symptoms:** After logging in at Authentik you are sent to `https://mail.tukangketik.net/webmail/?homepage`, then the page redirects in a loop and the browser hangs or crashes.

**Cause:** The callback URL (`https://mail.tukangketik.net/outpost.goauthentik.io/callback`) must be served by **Authentik** so it can set the session cookie. If Traefik does not allow cross-namespace refs, the route from `mailu` to the outpost service in `auth` fails, the callback never hits Authentik, and no cookie is set → every request triggers login again.

**Fix:** Enable Traefik’s `allowCrossNamespace` so the callback route can reach Authentik. See [Authentik setup for Mailu – section 5c](authentik-mailu-setup.md#5c-traefik-cross-namespace-fix-infinite-redirect-after-login): apply `deploy/traefik/k3s-allow-cross-namespace.yaml`, restart Traefik, sync Mailu.

### Traefik: secret auth/authentik-outpost-tls does not exist (Authentik outpost)

**Symptoms:** Traefik logs `Error configuring TLS error="secret auth/authentik-outpost-tls does not exist" ingress=ak-outpost-authentik-embedded-outpost namespace=auth`. You may also see **too many redirects** when using Mailu + Authentik.

**Cause:** Authentik's Kubernetes integration creates an Ingress for the Embedded Outpost that expects a TLS secret named `authentik-outpost-tls` in the `auth` namespace. If that secret is missing, Traefik fails to configure TLS for that ingress and routing can misbehave.

**Fix:** The **authentik** Argo CD Application includes a second source that deploys a cert-manager Certificate for this secret (`deploy/argocd/apps/authentik/outpost-tls-cert/`). Sync the **authentik** app in Argo CD; it will create the Certificate in the `auth` namespace and cert-manager will issue the cert and create the secret. After the secret exists (1–2 minutes), Traefik will stop erroring. If you use a different auth host than `auth.tukangketik.net`, edit `deploy/argocd/apps/authentik/outpost-tls-cert/certificate.yaml` and set `dnsNames` to your host, then sync the authentik app.

**Alternative:** In Authentik UI → **Applications** → **Outposts** → **Embedded Outpost** → Kubernetes connection: set **Kubernetes Ingress Secret Name** to `authentik-tls` (your existing server TLS secret), or add `ingress` to **Kubernetes Disabled Components** to stop creating the outpost Ingress (only if you don't need that ingress).

### Outpost Ingress claims mail host (wrong routing or redirect loop)

**Symptoms:** `kubectl get ingress -n auth` shows `ak-outpost-authentik-embedded-outpost` with host **mail.tukangketik.net** (same as Mailu). You get wrong routing or "too many redirects".

**Cause:** The Mailu IngressRoute (namespace `mailu`) is supposed to be the only thing handling **mail.tukangketik.net**. Authentik’s Kubernetes integration created an Ingress in `auth` for the same host, so Traefik has two resources for one host and routing breaks.

**Fix:**

1. In Authentik UI, disable the outpost Ingress (one of these):
   - **Applications** → **Outposts** → **Embedded Outpost** → edit → in **Configuration** / **Advanced** / YAML, set **Kubernetes Disabled Components** to include **`ingress`**.
   - Or **System** → **Integrations** → open the **Kubernetes** connection → add **`ingress`** to **Kubernetes Disabled Components**. Save.
2. Delete the wrong Ingress: `kubectl delete ingress -n auth ak-outpost-authentik-embedded-outpost`
3. Retry in a new incognito window. Only the Mailu IngressRoute should now handle mail.tukangketik.net (with callback going to the outpost service in auth (e.g. ak-outpost-authentik-embedded-outpost)).

If you can’t find the setting, see [Authentik setup – 4a. Disable outpost Ingress](authentik-mailu-setup.md#4a-disable-outpost-ingress-for-the-mail-host) for more paths and a kubectl-only option.

### Front stuck in ContainerCreating – secret mailu-certificates not found

**Symptoms:** `mailu-front` pod stays in `ContainerCreating`; `kubectl describe pod` shows the front container waiting for secret `mailu-certificates`.

**Cause:** The Mailu front deployment mounts a secret named `mailu-certificates` at `/certs`. The chart does not create this secret; it must be provided (e.g. by cert-manager).

**Resolution:** The wrapper chart includes a cert-manager **Certificate** (`templates/mailu-certificate.yaml`) that requests a TLS cert for the mail hostnames and stores it in a secret named `mailu-certificates`. After you deploy (or re-sync) the mailu app, cert-manager will create that secret; issuance can take 1–2 minutes. Ensure cert-manager and the `letsencrypt-prod` ClusterIssuer are installed, then:

1. In Argo CD: open the **mailu** app → **Refresh** → **Sync** (so the Certificate resource is applied).
2. Wait 1–2 minutes. Check: `kubectl get certificate -n mailu` and `kubectl get secret mailu-certificates -n mailu`.
3. Once the secret exists, the front pod should start; if not, `kubectl delete pod -n mailu -l app.kubernetes.io/component=front` to restart.

If the Certificate is not yet in Git, you can create it manually once (same hostnames and `secretName: mailu-certificates`, ClusterIssuer `letsencrypt-prod`), then cert-manager will create the secret.

### Client setup UI shows port 465 for SMTP

**Symptoms:** In Admin → Client setup, "Outgoing mail" shows **465 (TLS)** for SMTP.

**Cause:** The client setup page is part of the upstream Mailu admin app (`core/admin/mailu/ui/templates/client.html`) and hardcodes 465 when TLS is enabled. It is not configurable via Helm or env.

**What to tell users:** Use **port 587 with STARTTLS** for outgoing mail (we expose 587, not 465). Server: `mail.tukangketik.net`, port **587**, encryption: STARTTLS. You can ignore the 465 shown in the UI. To change the UI text you would need to open an issue or PR on [Mailu/Mailu](https://github.com/Mailu/Mailu) (e.g. show 587 or make the port configurable).

### Initial admin cannot log in

**Symptoms:** Cannot log in at https://mail.tukangketik.net/admin with the initial account (e.g. admin@tukangketik.net).

**Causes and fixes:**

1. **initialAccount must be under `mailu:`**  
   When using the wrapper chart, the Mailu subchart only receives values under the `mailu:` key. If `initialAccount` was at the top level of values, the chart never saw it. Ensure `deploy/argocd/apps/mailu/values.yaml` has `mailu.initialAccount` (under the `mailu:` block) with `enabled: true`, `username`, `domain`, and either `existingSecret` + `existingSecretPasswordKey` or `password`.

2. **Create the initial-account secret**  
   If using `existingSecret: mailu-initial-account`, the secret must exist with the key from `existingSecretPasswordKey` (e.g. `initial-account-password`):
   ```bash
   ./scripts/create-mailu-initial-account-secret.sh
   # or manually:
   kubectl create secret generic mailu-initial-account -n mailu --from-literal=initial-account-password='YourChosenPassword'
   ```
   Then restart the admin so it (re)runs initial account creation:
   ```bash
   kubectl rollout restart deployment -n mailu -l app.kubernetes.io/component=admin
   ```

3. **Create admin manually (fallback)**  
   If the chart’s initial account never ran or the password is unknown, create the admin in the admin pod:
   ```bash
   kubectl exec -n mailu deployment/mailu-admin -- flask mailu admin admin tukangketik.net 'YourNewPassword'
   ```
   Then log in at https://mail.tukangketik.net/admin as **admin@tukangketik.net** with that password.

### Postfix: two pods / old ReplicaSet not scaled down automatically

**Symptoms:** Deployment has `replicas: 1` but two Postfix pods are running; one is from an old ReplicaSet and stays until you scale that ReplicaSet to 0.

**Why the old ReplicaSet isn’t removed automatically:**  
The Deployment controller only scales the **old** ReplicaSet to 0 when the **new** ReplicaSet has enough **Ready** pods. If the new Postfix pod never becomes Ready (e.g. readiness probe fails because only one instance can use the mail queue, or the new pod is stuck), the rollout never completes and the controller keeps the old ReplicaSet running. So the old replica is left on purpose until the new revision is healthy.

**What to do:**

1. **One-off cleanup** – Scale old ReplicaSets to 0 so only the current revision runs:
   ```bash
   ./scripts/mailu-postfix-cleanup-replicasets.sh
   ```
   Or manually: list ReplicaSets with `kubectl get rs -n mailu -l app.kubernetes.io/component=postfix`, then
   `kubectl scale rs <old-replicaset-name> -n mailu --replicas=0` for the non-current revision.

2. **Stop it recurring** – Ensure the **new** Postfix pod can become Ready (fix readiness probe, storage, or single-instance constraints). Then future rollouts will complete and the controller will scale down the old ReplicaSet automatically.

### Port 25 (SMTP) connection timeout from outside

**Symptoms:** UFW allows port 25, but `telnet your-server 25` from the internet times out.

**Common cause: cloud provider blocks port 25**  
Many VPS providers (DigitalOcean, Linode, Vultr, AWS, etc.) block **inbound and/or outbound** port 25 at their network edge to reduce spam. Traffic never reaches your host, so UFW is not the bottleneck.

**What to do:**

1. **Verify on the host** that something is listening and UFW allows it:
   ```bash
   sudo ufw status | grep 25
   sudo ss -tlnp | grep :25
   # or: sudo netstat -tlnp | grep :25
   ```
   If nothing listens on 25, the Mailu front LoadBalancer may not have an external IP yet, or K3s isn’t binding the service to the node.

2. **Check with your provider**  
   - DigitalOcean: [Why is SMTP blocked?](https://docs.digitalocean.com/support/why-is-smtp-blocked) – request unblock via support.  
   - Linode / Vultr / others: open a support ticket asking to allow **inbound** port 25 (and 587, 465 if you need them) for your VPS IP; mention you run a mail server and use authentication/rate limits.

3. **Test from inside the same network**  
   From another host on the same provider/DC, or from the VPS to itself: `telnet <public-ip> 25`. If it works locally but not from the internet, the block is at the provider.

4. **LoadBalancer / K3s**  
   Ensure the Mailu front service has an external IP and port 25 is in the service’s port list:
   ```bash
   kubectl get svc -n mailu -l app.kubernetes.io/component=front
   ```
   On a single-node K3s, the LoadBalancer often gets the node IP; then UFW (and the provider) must allow 25 to that IP.

### Redeploy Mailu from scratch (remove all old revisions)

Use this when you want a clean install with no old ReplicaSets, failed pods, or leftover resources.

**Automated script (recommended):** From the repo root (with `KUBECONFIG` set):

```bash
# Light: wipe namespace + PVs, recreate ns + secrets; Argo CD redeploys on Sync (no app delete)
LIGHT_REDEPLOY=1 ./scripts/reinstall-mailu-from-scratch.sh
```

Or full reinstall (also deletes and re-applies the Argo CD Application):

```bash
./scripts/reinstall-mailu-from-scratch.sh
```

The script deletes the namespace and cleans PVs bound to `mailu`, recreates the namespace, runs `create-mailu-secret.sh` and `create-mailu-initial-account-secret.sh`; in light mode it leaves the Application in place so a Refresh + Sync is enough to redeploy everything. Use `SKIP_PV_CLEANUP=1` or `SKIP_SECRETS=1` if needed.

**Manual steps (if you prefer):**

**1. (Optional) Back up secrets** if you want to keep the same secret key and admin password:

```bash
kubectl get secret mailu-secret mailu-initial-account -n mailu -o yaml > mailu-secrets-backup.yaml
```

**2. Delete the Argo CD Application** so Argo CD removes all Mailu resources (including old ReplicaSets):

```bash
# Delete the app and its resources (namespace-scoped resources in mailu namespace)
argocd app delete mailu --cascade

# If you don't use argocd CLI, do the same from the UI: Application → Delete → check "Cascade" so resources are removed.
```

Or with kubectl (if the Application is managed by app-of-apps, delete the Application manifest and the namespace):

```bash
kubectl delete application mailu -n argocd
kubectl delete namespace mailu
```

**3. (Optional) Wipe persistent data** for a fully fresh state (you will lose mail data and DB):

```bash
kubectl delete pvc -n mailu --all
# Then delete the namespace if not already deleted:
kubectl delete namespace mailu --ignore-not-found
```

**4. Recreate the Application and sync**

- If you use **app-of-apps**: the mailu Application is defined in Git (e.g. under `deploy/argocd/apps/`). Sync the app-of-apps parent so it recreates the mailu Application, then the mailu app will sync and deploy Mailu again.
- Or apply the Application manifest manually:

```bash
kubectl apply -f deploy/argocd/apps/mailu/mailu.application.yaml
# Then in Argo CD UI: open mailu → Refresh → Sync
```

**5. Restore secrets** if you backed them up and the namespace was recreated:

```bash
# Edit mailu-secrets-backup.yaml: remove metadata.resourceVersion, metadata.uid, metadata.creationTimestamp, status
kubectl apply -f mailu-secrets-backup.yaml
```

**6. Re-create secrets** if you didn’t back them up:

```bash
./scripts/create-mailu-secret.sh
./scripts/create-mailu-initial-account-secret.sh
```

Then trigger a sync (or rollout restart of the admin deployment if you use initialAccount).

---

## Backup & restore

For infra-only, focus on:

- Authentik configuration (exports, recovery codes)
- Git repositories (infra and services/content)

When an app database is added, add a database backup/restore procedure here.

**Export secrets (plaintext; store securely):**

```bash
kubectl get secrets --all-namespaces -o yaml > secrets-backup.yaml
```

---

## Security incidents

### Suspicious activity

```bash
kubectl logs -n auth deployment/authentik | grep -i "failed"
# Block IP on VPS: sudo ufw deny from SUSPICIOUS_IP to any
# Review Authentik UI: failed logins, active sessions
```

### Compromised account

1. Disable the account in Authentik UI.  
2. Revoke all sessions for that user in Authentik UI.  
3. Rotate secrets (e.g. `kubectl delete secret -n auth <secret>`, recreate with new values).  
4. Restart affected services as needed.

### Vulnerability in an image

```bash
kubectl get pods --all-namespaces -o wide
kubectl get deployment --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}'
# Rebuild and deploy patched images; verify with trivy or similar
```

---

## Maintenance

### Update k3s

```bash
# On VPS
k3s --version
curl -sfL https://get.k3s.io | sh -
kubectl get nodes
kubectl get pods --all-namespaces
```

### Rotate certificates

Let's Encrypt certificates renew automatically via cert-manager. To force renewal, delete the Certificate resource; cert-manager will reissue:

```bash
kubectl delete certificate -n <namespace> <cert-name>
```

### Check disk usage

```bash
df -h
kubectl get pvc --all-namespaces
```

### Adding new services

Use the service template in the services repo and create the deployment; register a dedicated Argo CD Application if using GitOps for that service.

### Disaster recovery

**Corrupted etcd (k3s):**

```bash
sudo systemctl stop k3s
sudo rm -rf /var/lib/rancher/k3s/server/db
sudo systemctl start k3s
# Re-apply manifests from Phase 3 onwards
```

**Full cluster recovery:** Restore from Git (namespaces, Argo CD project and app-of-apps); restore databases from backup; Argo CD will sync applications from the repo.
