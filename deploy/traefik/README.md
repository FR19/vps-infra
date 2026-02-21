# Traefik configuration (K3s)

K3s ships with Traefik as the default ingress controller. This folder holds optional config so Traefik works with cross-namespace IngressRoutes (e.g. Mailu → Authentik callback).

## Enable allowCrossNamespace

Required for **Mailu + Authentik** when the callback route (`/outpost.goauthentik.io/*` on the mail host) must reach the Authentik server in the `auth` namespace. Without this, the IngressRoute in `mailu` cannot reference the service `authentik-server` in `auth`, which causes infinite redirects after login.

**Steps:**

1. Apply the HelmChartConfig (once):
   ```bash
   kubectl apply -f deploy/traefik/k3s-allow-cross-namespace.yaml
   ```

2. Restart Traefik so it picks up the new provider setting:
   ```bash
   kubectl rollout restart deployment -n kube-system -l app.kubernetes.io/name=traefik
   ```
   (If Traefik runs as a DaemonSet, use `kubectl rollout restart daemonset -n kube-system -l app.kubernetes.io/name=traefik`.)

3. Sync the Mailu app in Argo CD.

**Reference:** [Traefik Kubernetes CRD – allowCrossNamespace](https://doc.traefik.io/traefik/v2.4/providers/kubernetes-crd/#allowcrossnamespace)

### If HelmChartConfig doesn’t take effect

Some K3s setups use a different Traefik chart. You can pass the flag via `additionalArguments` instead. Edit the HelmChartConfig or create one with:

```yaml
spec:
  valuesContent: |-
    additionalArguments:
      - "--providers.kubernetescrd.allowCrossNamespace=true"
```

Then re-apply and restart Traefik.
