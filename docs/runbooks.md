# Runbooks

Operational procedures for platform infrastructure. Use these when something fails or when performing maintenance.

## Table of contents

- [Emergency procedures](#emergency-procedures)
- [Authentik](#authentik)
- [Argo CD](#argocd)
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

---

## Authentik

### Unhealthy / startup probe failed / "Secret key missing"

**Symptoms:** Authentik server pods fail startup; logs show "Secret key missing" or "no password supplied" (Postgres).

**Cause:** Required one-time Secrets are missing: `authentik-secret-key` (cookie signing) and `authentik-postgresql` (DB password for the PostgreSQL subchart).

**Resolution:**

```bash
./infra/scripts/create-auth-secret.sh
./infra/scripts/create-auth-db-secret.sh
kubectl rollout restart deployment -n auth -l app.kubernetes.io/name=authentik
```

### PostgreSQL password authentication failed

**Symptoms:** Authentik server or worker logs: "password authentication failed" or "no password supplied" when connecting to PostgreSQL.

**Cause:** PostgreSQL was created before the `authentik-postgresql` Secret existed (or with a different password). The database was initialized with another password; Authentik is using the Secret, so they do not match.

**Resolution:** Recreate PostgreSQL so it initializes with the Secret password. This **wipes Authentik's database** (acceptable for a fresh install).

1. Ensure the Secret exists: `./infra/scripts/create-auth-db-secret.sh`
2. Run: `./infra/scripts/recreate-auth-postgres.sh`

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
   helm dependency update infra/deploy/argocd/helm
   helm upgrade --install argocd infra/deploy/argocd/helm -n argocd -f infra/deploy/argocd/helm/values.yaml
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

1. **TLS secret missing:** Certificate must be Ready before the secret exists. Check `kubectl get certificate,order,challenge -n argocd`. For HTTP-01, ensure the Argo CD hostname resolves to the VPS and port 80 is reachable. Check cert-manager logs: `kubectl logs -n cert-manager -l app=cert-manager`. Optional: `./infra/scripts/diagnose-argocd-tls.sh`.

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
