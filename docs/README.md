# Documentation

This folder contains guides and reference material for deploying and operating the platform. Unless stated otherwise, **all paths are relative to the infra repository root**.

## Getting started

| Guide | Description |
|-------|-------------|
| [deployment-infra.md](deployment-infra.md) | Deploy base infrastructure (cert-manager, Argo CD, Authentik) on K3s |
| [runbooks.md](runbooks.md) | Operational procedures and troubleshooting |

## Email (Mailu)

| Guide | Description |
|-------|-------------|
| [mailu-install.md](mailu-install.md) | Install and configure Mailu via Argo CD |
| [authentik-mailu-setup.md](authentik-mailu-setup.md) | Protect the Mailu web UI with Authentik forward auth |

## Argo CD SSO

| Guide | Description |
|-------|-------------|
| [authentik-argocd-sso.md](authentik-argocd-sso.md) | Configure Argo CD login via Authentik (OIDC) |

## VPN / Tailnet (Headscale + in-cluster proxy)

| Guide | Description |
|-------|-------------|
| [vpn-headscale.md](vpn-headscale.md) | Headscale VPN, VPN-only Argo CD, and device enrollment |
| [vpn-only-apps.md](vpn-only-apps.md) | Add VPN-only apps behind `incluster-vpn` (DNS + TLS + reverse proxy) |

## Headscale / Headplane SSO

| Guide | Description |
|-------|-------------|
| [headscale-authentik-sso.md](headscale-authentik-sso.md) | Configure Headscale OIDC login via Authentik |
| [headplane-authentik-sso.md](headplane-authentik-sso.md) | Configure Headplane OIDC login via Authentik |

## Reference

| Doc | Description |
|-----|-------------|
| [architecture.md](architecture.md) | System architecture overview |
| [repo-structure.md](repo-structure.md) | Recommended repo split and layout |
| [auth.md](auth.md) | Auth/JWT conventions across services |
