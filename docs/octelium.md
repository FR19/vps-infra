# Octelium VPN (self-hosted on your existing K3s)

This guide covers installing both the **Octelium cluster** (control plane) and the **Octelium client** on your **single VPS** — the same K3s cluster that runs Argo CD, Authentik, etc. No second machine is required.

## Overview

- **Octelium cluster** = control plane (API, gateways, etc.) installed with `octops init` on your existing Kubernetes.
- **Octelium client** = workload deployed by this repo (Argo CD app `octelium-client`) that connects to the cluster and can expose in-cluster services (e.g. Argo CD) over the VPN.
- Both run in the same K3s cluster; the cluster uses the `octelium` namespace (created by `octops init`). You install the cluster first, then deploy the client via Argo CD.
- **Optional (later):** Once VPN works, you can make Argo CD reachable only via VPN by disabling its public Ingress.

## Prerequisites

- One VPS with K3s already installed (your current infra).
- A domain (or subdomain) you control for Octelium (e.g. `octelium.tukangketik.net`).
- `kubectl` and `octops` CLI (see [Install CLI tools](https://octelium.com/docs/octelium/latest/install/cli/install)).

## Where to run commands

| Where | Commands |
|-------|----------|
| **Local (your laptop)** | Any command that uses `kubectl` or `octops` **if** your `KUBECONFIG` points at the VPS cluster (e.g. you copied the kubeconfig from the VPS or use a tunnel). Same for `argocd` CLI. |
| **VPS (SSH into the server)** | You can run **all** cluster-related commands here instead: `kubectl`, `octops`, `argocd`. Use the VPS kubeconfig (e.g. `/etc/rancher/k3s/k3s.yaml` on the node). Cloning the repo on the VPS gives you the bootstrap path for `octops init`; otherwise copy `bootstrap.yaml` to the VPS or run `octops init` from local with the path to your local clone. |
| **Local only** | **Part 6 (Verify VPN):** `octelium login` and `octelium connect` run on your **laptop** (the Octelium CLI is your VPN client). |

**Summary:** Use either (1) **local** with `KUBECONFIG` pointing at the VPS cluster, or (2) **SSH to the VPS** and run everything there. Part 6 (VPN login/connect) is always on the machine where you want VPN (usually your laptop).

---

## Part 1: Prepare the cluster

### 1.1 Label the node

You have one node. Octelium allows the same node to act as both control-plane and data-plane for personal/small setups. Replace `NODE_NAME` with your node name (`kubectl get nodes`):

```bash
kubectl label nodes NODE_NAME octelium.com/node-mode-dataplane=
kubectl label nodes NODE_NAME octelium.com/node-mode-controlplane=
```

### 1.2 Install Multus CNI

Octelium requires [Multus](https://github.com/k8snetworkplumbingwg/multus-cni). K3s uses containerd, so:

```bash
kubectl apply -f https://raw.githubusercontent.com/k8snetworkplumbingwg/multus-cni/master/deployments/multus-daemonset.yml
```

K3s uses a non-standard CNI path. **Find the path on your VPS** (run on the VPS):

```bash
# Common locations (one of these usually exists when K3s is running)
ls -la /var/lib/rancher/k3s/agent/etc/cni/net.d 2>/dev/null || true
ls -la /etc/cni/net.d 2>/dev/null || true

# Or search under k3s
find /var/lib/rancher/k3s -name "net.d" -type d 2>/dev/null
```

Use the directory that contains CNI config files (e.g. `10-flannel.conflist` or similar). Then, before running `octops init` (Part 3), set:

```bash
export OCTELIUM_CNI_CONF_DIR=/path/you/found   # e.g. /var/lib/rancher/k3s/agent/etc/cni/net.d or /etc/cni/net.d
```

On some K3s versions the `agent` tree is created only after the node is fully up; if `agent/etc/cni/net.d` is missing, try `/etc/cni/net.d` or the path from the `find` output. See [K3s networking](https://docs.k3s.io/networking) and [Multus on K3s](https://docs.k3s.io/networking/multus-ipams).

### 1.3 PostgreSQL and Redis (source of truth in repo)

Octelium needs PostgreSQL (primary store) and Redis (cache/pub-sub). This repo deploys both via Argo CD so the config is the source of truth.

- **Bootstrap config:** [deploy/argocd/apps/octelium-cluster/bootstrap.yaml](deploy/argocd/apps/octelium-cluster/bootstrap.yaml) — references Secrets for passwords (no secrets in Git).
- **PostgreSQL:** Argo CD Application [octelium-cluster/octelium-postgresql.application.yaml](deploy/argocd/apps/octelium-cluster/octelium-postgresql.application.yaml) (Bitnami chart in namespace `octelium-storage`).
- **Redis:** Argo CD Application [octelium-cluster/octelium-redis.application.yaml](deploy/argocd/apps/octelium-cluster/octelium-redis.application.yaml) (Bitnami chart in namespace `octelium-storage`).

**One-time: create Secrets** in namespace `octelium-storage` (do not commit real passwords):

```bash
kubectl create namespace octelium-storage --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic octelium-pg -n octelium-storage \
  --from-literal=password='YOUR_PG_PASSWORD' \
  --from-literal=postgres-password='YOUR_PG_ADMIN_PASSWORD'

kubectl create secret generic octelium-redis -n octelium-storage \
  --from-literal=password='YOUR_REDIS_PASSWORD'
```

Then sync the apps (or let app-of-apps sync): `argocd app sync octelium-postgresql octelium-redis`. Wait until both are healthy.

**External PostgreSQL/Redis:** If you use external stores instead, edit [bootstrap.yaml](deploy/argocd/apps/octelium-cluster/bootstrap.yaml) to point to your hosts and credentials (or `passwordFromSecret` in another namespace).

---

## Part 3: Install the Octelium cluster

Run from **local** (with `KUBECONFIG` pointing at the VPS) or from **the VPS** (see [Where to run commands](#where-to-run-commands)). You need `kubectl` and `octops` and access to the cluster.

1. **Set environment variables** (single-node VPS; optional if you use Traefik in front):

   ```bash
   export OCTELIUM_REGION_EXTERNAL_IP=YOUR_VPS_PUBLIC_IP
   export OCTELIUM_CNI_CONF_DIR=/path/you/found   # same as in Part 1.2 (e.g. /etc/cni/net.d)
   ```

   If you will put Octelium behind **Traefik** (recommended so Traefik handles TLS and you reuse cert-manager), also set:

   ```bash
   export OCTELIUM_FRONT_PROXY_MODE=true
   ```

   Then Octelium’s Ingress listens on port 8080 (no TLS); you’ll add a Traefik IngressRoute or Ingress for your Octelium domain pointing to `octelium-ingress-dataplane.octelium.svc:8080`.

2. **Install the cluster** using the bootstrap config from this repo:

   ```bash
   # From repo root (or pass the path where you cloned the repo)
   octops init octelium.tukangketik.net --bootstrap deploy/argocd/apps/octelium-cluster/bootstrap.yaml --kubeconfig /path/to/kubeconfig
   ```

   Replace `octelium.tukangketik.net` with your domain. Use the path to [deploy/argocd/apps/octelium-cluster/bootstrap.yaml](deploy/argocd/apps/octelium-cluster/bootstrap.yaml) (from your clone). Omit `--kubeconfig` if using default.

   This creates the `octelium` namespace and all cluster components. Wait until it finishes.

3. **DNS:** Create an **A** record for your Octelium domain pointing to your VPS public IP, and a **CNAME** for `*.octelium.tukangketik.net` pointing to `octelium.tukangketik.net`.

4. **TLS:** If you did **not** use `OCTELIUM_FRONT_PROXY_MODE=true`, configure the cluster TLS certificate as in [Octelium TLS](https://octelium.com/docs/octelium/latest/install/cluster/tls-certificate). If you **did** use front-proxy mode, configure TLS in Traefik (e.g. cert-manager + Ingress for your Octelium domain).

---

## Part 4: Create an auth token for the client

The Octelium client (Helm chart) needs a **workload** user and an auth token.

1. **Create a WORKLOAD user** (run once; use your Octelium domain). If your `octeliumctl` supports it:
   ```bash
   octeliumctl create user k8s-client --type WORKLOAD --domain octelium.tukangketik.net
   ```
   Otherwise create the user via the Octelium API/portal (User with `spec.type: WORKLOAD`) or by applying a User manifest; see [Users](https://octelium.com/docs/octelium/latest/management/core/user).

2. **Create a credential (auth token)** for that user:

   ```bash
   octeliumctl create cred --user k8s-client --domain octelium.tukangketik.net my-cred
   ```

   The command outputs a token. **Save it**; you’ll put it in a Kubernetes Secret next.

3. **Create the Secret** in the `octelium` namespace (cluster already created it):

   ```bash
   kubectl create secret generic octelium-auth-token -n octelium --from-literal=data="PASTE_TOKEN_HERE"
   ```

   The Argo CD app expects the Secret name `octelium-auth-token` and key `data`.

---

## Part 5: Deploy the Octelium client via Argo CD

1. **Set your domain** in the Application. Edit `deploy/argocd/apps/octelium-client/octelium-client.application.yaml` and in the `helm.values` section set:
   - `octelium.domain` to your Octelium cluster domain (e.g. `octelium.tukangketik.net`).
   - `octelium.authTokenSecret` can stay `octelium-auth-token` if you used that name above.

2. **Commit and push** (so Argo CD sees the change), then sync:

   ```bash
   argocd app sync infra-app-of-apps
   argocd app sync octelium-client
   ```

3. **Check the client:**

   ```bash
   kubectl get pods -n octelium
   kubectl logs -n octelium -l app.kubernetes.io/name=octelium -f
   ```

---

## Part 6: Verify VPN access

1. **Install the Octelium CLI** on your laptop: [Install CLI tools](https://octelium.com/docs/octelium/latest/install/cli/install).

2. **Log in** (you need a **human** user and token for the CLI; create a user and cred via the Octelium portal or `octeliumctl` if you haven’t already):

   ```bash
   octelium login --domain octelium.tukangketik.net --auth-token YOUR_HUMAN_AUTH_TOKEN
   ```

3. **Connect:**

   ```bash
   octelium connect
   ```

4. **Optional – expose Argo CD over Octelium:** Create an Octelium **Service** in the cluster whose upstream is `http://argocd-server.argocd.svc.cluster.local`, then add that Service name to `octelium.serve` in the client’s Helm values. See [Octelium Helm Kubernetes guide](https://octelium.com/docs/octelium/latest/management/guide/service/devops/octelium-helm-kubernetes). After that works, you can disable Argo CD’s public Ingress so it’s only reachable via VPN.

---

## Troubleshooting

- **octops init fails (CNI):** Ensure Multus is installed and `OCTELIUM_CNI_CONF_DIR` points to the CNI config dir on your VPS (see [Part 1.2](#12-install-multus-cni) — find the `net.d` path on the VPS).
- **Client pod not connecting:** Check pod logs; confirm the auth token Secret exists in `octelium` and the domain is reachable (TLS valid or `OCTELIUM_INSECURE_TLS=true` for testing).
- **Namespace conflict:** Install the Octelium cluster with `octops init` **before** syncing the `octelium-client` Argo CD app. `octops init` creates/overwrites the `octelium` namespace; the client is then added to the same namespace.
- **Chart version:** The Application may pin `targetRevision`; check [Octelium Helm charts](https://github.com/octelium/octelium) and update if needed.

## References

- [Installing a Cluster (existing Kubernetes)](https://octelium.com/docs/octelium/latest/install/cluster/installing-cluster)
- [Pre-installation considerations](https://octelium.com/docs/octelium/latest/install/cluster/pre-install)
- [Bootstrap config](https://octelium.com/docs/octelium/latest/install/cluster/bootstrap)
- [Octelium Helm – deploy clients in Kubernetes](https://octelium.com/docs/octelium/latest/management/guide/service/devops/octelium-helm-kubernetes)
- [Octelium docs](https://octelium.com/docs)
