# Deployment Guide

This document indexes deployment documentation for the platform.

| Guide | Description |
|-------|-------------|
| [deployment-infra.md](deployment-infra.md) | Deploy platform infrastructure (cert-manager, Argo CD, Authentik) on a K3s cluster |
| [mailu-install.md](mailu-install.md) | Install and configure Mailu (mail server) via Argo CD |
| [authentik-argocd-sso.md](authentik-argocd-sso.md) | Configure Argo CD SSO with Authentik (OIDC) |
| [authentik-mailu-setup.md](authentik-mailu-setup.md) | Protect Mailu web UI with Authentik forward auth |

All paths in the guides are relative to the **infra repository root** unless stated otherwise.
