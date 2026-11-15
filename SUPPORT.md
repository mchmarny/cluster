# Support

Where to go depends on what you need.

| Need | Where |
|------|-------|
| A bug or a scoped feature request | [GitHub Issues](https://github.com/mchmarny/cluster/issues/new/choose) |
| A question, or help using the toolkit | A [blank issue](https://github.com/mchmarny/cluster/issues/new) |
| A security vulnerability | Follow [SECURITY.md](SECURITY.md); do not open a public issue |

## Before You Ask

- Read the [README](README.md) and the guide for your provider: [EKS](provider/eks/README.md), [GKE](provider/gke/README.md), [AKS](provider/aks/README.md) or [OKE](provider/oke/README.md).
- Search [existing issues](https://github.com/mchmarny/cluster/issues?q=is%3Aissue) for the same problem.

## What to Include

Redact credentials, account and tenancy IDs, and other sensitive values from everything you share. `KEY_CONTENT` and `CONFIG_CONTENT` are base64 and decode to credentials and configuration, so never paste them.

- The image and version, for example `ghcr.io/mchmarny/cluster/eks:v0.5.4` (`docker run --rm <image> --version`).
- The provider and region.
- The command you ran (`plan`, `apply` or `output`) and its full output.
- The relevant part of your configuration file.

Contributing code or docs? See [CONTRIBUTING.md](CONTRIBUTING.md).
