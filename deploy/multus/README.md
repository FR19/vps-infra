# Multus CNI (source of truth)

Required for Octelium. Apply from repo root:

```bash
kubectl apply -f deploy/multus/multus-daemonset.yaml
```

- **Paths:** Uses `/etc/cni/net.d` and `/opt/cni/bin` (adjust in the DaemonSet if your node uses different paths).
- **Memory:** DaemonSet sets `resources.limits.memory: 200Mi` to avoid OOMKilled; increase if needed.
- **Config:** Uses an explicit config file (`70-multus.conf` from the ConfigMap) instead of auto-discovery, so no master conflist is required in `/etc/cni/net.d` (works when K3s does not put one there). The config delegates the default network to flannel.
- **Recovery:** If Multus breaks the cluster, see [runbooks: Multus CrashLoopBackOff](docs/runbooks.md#multus-crashloopbackoff--cannot-access-argocd-authentik-etc).
