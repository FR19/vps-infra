# VPN-only apps (incluster-vpn)

Internal services are exposed over the Headscale/Tailscale tailnet using an in-cluster VPN proxy. No public Ingress is required; access is limited to clients on the VPN.

## Overview

| Component | Purpose |
|-----------|---------|
| **incluster-vpn** | Pod that joins the tailnet, terminates TLS (Caddy), and reverse-proxies to in-cluster Services. VPN-only access is enforced by Caddy (`remote_ip 100.64.0.0/10`). |
| **tailscale-dns** | CoreDNS that resolves `*.tukangketik.net` (and other configured hostnames) to tailnet IPs so VPN clients reach the proxy instead of the public internet. |

Paths below are relative to the **infra repository root**.

---

## Files you edit

| Goal | File |
|------|------|
| DNS: hostname → tailnet IP | `deploy/argocd/apps/tailscale-dns/manifests/configmap.yaml` — add a line under `tukangketik.hosts` with the **incluster-vpn** pod’s tailnet IP. |
| Reverse proxy + VPN allowlist | `deploy/argocd/apps/incluster-vpn/manifests/configmap.yaml` — add a Caddy host block with `remote_ip 100.64.0.0/10 127.0.0.1/32`. |
| TLS for new hostname | `deploy/argocd/apps/incluster-vpn/manifests/` — add a cert-manager `Certificate` (e.g. DNS-01 via OVH), then mount the issued secret into the incluster-vpn pod. |

---

## Example: add `ctf.tukangketik.net` (VPN-only)

Assume the app is reachable in-cluster as:

- **Service:** `ctf-frontend.ctf.svc.cluster.local`
- **Port:** `80`

### 1. DNS — point hostname at the incluster-vpn tailnet IP

Edit `deploy/argocd/apps/tailscale-dns/manifests/configmap.yaml`. Under the `tukangketik.hosts` block, add a line (format: `IP hostname`):

```text
100.64.0.2 ctf.tukangketik.net
```

- Use the **current** tailnet IP of the **incluster-vpn** pod (e.g. from `kubectl get pods -n incluster-vpn -o wide` or the Tailscale admin). Do not use the VPS tailnet IP for this hostname if the proxy is the incluster-vpn pod.
- All VPN-only hostnames that are served by the same proxy should point to the same tailnet IP.

### 2. Certificate — TLS for the new hostname

Create `deploy/argocd/apps/incluster-vpn/manifests/certificate-ctf.yaml`:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: ctf-tukangketik-net
  namespace: incluster-vpn
spec:
  secretName: incluster-vpn-ctf-tls
  issuerRef:
    kind: ClusterIssuer
    name: letsencrypt-prod-ovh-dns01
  dnsNames:
    - ctf.tukangketik.net
```

Add it to `deploy/argocd/apps/incluster-vpn/manifests/kustomization.yaml` under `resources:` (e.g. `- certificate-ctf.yaml`).

### 3. Mount the TLS secret in the incluster-vpn pod

Edit `deploy/argocd/apps/incluster-vpn/manifests/deployment.yaml`.

**Add a volume** (under `spec.template.spec.volumes`):

```yaml
- name: ctf-tls
  secret:
    secretName: incluster-vpn-ctf-tls
```

**Add a volumeMount** to the **caddy** container (under `volumeMounts`):

```yaml
- name: ctf-tls
  mountPath: /certs/ctf
  readOnly: true
```

cert-manager issues the secret with keys `tls.crt` and `tls.key`; Caddy expects those filenames in the mount path.

### 4. Caddy host block (VPN allowlist + reverse proxy)

Edit `deploy/argocd/apps/incluster-vpn/manifests/configmap.yaml`. Add a block like:

```caddyfile
ctf.tukangketik.net:443 {
  tls /certs/ctf/tls.crt /certs/ctf/tls.key

  @vpn remote_ip 100.64.0.0/10 127.0.0.1/32
  handle @vpn {
    reverse_proxy http://ctf-frontend.ctf.svc.cluster.local:80
  }
  respond 403
}
```

### 5. Sync order in Argo CD

1. Sync **cert-manager-webhook-ovh** (if used) and **cert-manager-issuers**.
2. Sync **incluster-vpn** (Certificate, Caddy config, and new volume/mount).
3. Sync **tailscale-dns** (updated hosts).

### 6. Test from a VPN-connected client

**DNS** (resolver is the tailscale-dns service; use the resolver IP your client uses for `*.tukangketik.net`, e.g. `100.64.0.1`):

```bash
nslookup ctf.tukangketik.net 100.64.0.1
```

**HTTPS** (use the incluster-vpn pod’s tailnet IP for the test; SNI must match the hostname):

```bash
curl -vk --resolve ctf.tukangketik.net:443:100.64.0.2 https://ctf.tukangketik.net/
```

From **off VPN**, the hostname should not be reachable (or should resolve to a different IP); there is no public Ingress for this app.

---

## Notes

- **No public Ingress:** Keep VPN-only apps as ClusterIP and expose them only via `incluster-vpn`.
- **Tailnet IP changes:** If the incluster-vpn pod’s tailnet IP changes, update `tukangketik.hosts` in the tailscale-dns ConfigMap and sync the app.
- **TLS by IP:** Access must be by hostname (SNI). When testing by IP, use `curl --resolve hostname:443:ip`.

---

## See also

- [vpn-headscale.md](vpn-headscale.md) — Headscale VPN setup, VPN-only Argo CD, and device enrollment
- [headscale-authentik-sso.md](headscale-authentik-sso.md) — Headscale OIDC login via Authentik
