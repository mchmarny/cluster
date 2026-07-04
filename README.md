# Cluster

Opinionated Kubernetes cluster deployment toolkit. Provides Terraform configurations with sensible defaults and YAML-based customization for EKS (AWS), GKE (Google Cloud), AKS (Azure), and OKE (Oracle Cloud).

## Platforms

| Platform | Directory | Features |
|----------|-----------|----------|
| [AWS (EKS)](./provider/eks/) | `provider/eks/` | Multi-AZ, optional VPC CNI custom networking, self-managed nodes, CloudWatch |
| [Google Cloud (GKE)](./provider/gke/) | `provider/gke/` | Regional cluster, Workload Identity, Shielded Nodes, multi-NIC GPU networking for GPUDirect-TCPXO (a3-megagpu-8g) |
| [Azure (AKS)](./provider/aks/) | `provider/aks/` | Private cluster, Entra ID RBAC, OIDC + Workload Identity, VNet/NSG + NAT gateway, Key Vault etcd encryption |
| [Oracle (OKE)](./provider/oke/) | `provider/oke/` | Private cluster, OCI_VCN_IP_NATIVE pod networking, VCN with NAT/service gateways, dynamic-group IAM |

> **Note:** AKS and OKE are newly added and pending live validation against Azure/Oracle accounts. They are complete and statically validated (`terraform validate`, `go test`, schema checks) but have not yet been exercised end-to-end against live cloud APIs. EKS and GKE are validated.

## Usage

1. **Generate config** (optional) -- run `init` to create a starter YAML, or copy from `config/`
2. **Discover versions** (optional) -- find latest K8s versions and AMIs for your region
3. **Setup tenancy** (one-time) -- bootstrap cloud account with state bucket and IAM credentials
4. **Apply** -- deploy the cluster using the container image with your config and key
5. **Destroy** -- set `deployment.destroy: true` in config and re-run apply

See provider-specific guides for detailed steps: [EKS](./provider/eks/) | [GKE](./provider/gke/) | [AKS](./provider/aks/) | [OKE](./provider/oke/)

## Container Images

Self-contained actuator images with pre-mirrored Terraform providers. Multi-arch (amd64 + arm64) built on native runners.

| Platform | Image |
|----------|-------|
| EKS | `ghcr.io/mchmarny/cluster/eks:<version>` |
| GKE | `ghcr.io/mchmarny/cluster/gke:<version>` |
| AKS | `ghcr.io/mchmarny/cluster/aks:<version>` |
| OKE | `ghcr.io/mchmarny/cluster/oke:<version>` |

Check image version:

```bash
docker run --rm ghcr.io/mchmarny/cluster/gke:<version> --version
docker run --rm ghcr.io/mchmarny/cluster/eks:<version> --version
```

### CLI Commands

| Command | Description |
|---------|-------------|
| `init <path>` | Generate a starter configuration file (provider-aware by filename prefix: `gke-*`, `aks-*`, `oke-*`, else EKS) |
| `plan -c <config>` | Show Terraform plan output without applying |
| `apply -c <config>` | Deploy or destroy infrastructure via Terraform |
| `output -c <config>` | Retrieve Terraform outputs and save to state directory |

Destroy is triggered by setting `deployment.destroy: true` in the config and running `apply`.

### Configuration Input

| Method | Flag / Env Var | Description |
|--------|---------------|-------------|
| File path | `-c` / `CONFIG_PATH` | Path to YAML config file |
| Base64 content | `CONFIG_CONTENT` | Base64-encoded YAML config |
| Base64 key | `KEY_CONTENT` | Base64-encoded credentials (AWS key JSON, GCP ADC JSON, or OCI S3-compat key `access:secret`) |

## Architecture

See [docs/architecture.md](docs/architecture.md) for project layout, configuration design, security model, and image build details.

## Development

```bash
make qualify      # All quality checks (Go + Terraform)
make go-qualify   # Go: vet, fmt, lint, test, build
make tf-qualify   # Terraform: validate, lint, fmt, trivy scan
make e2e          # Full end-to-end (qualify + Docker build + smoke tests)
make tools-check  # Verify tool versions match .settings.yaml
```

## License

MIT -- see [LICENSE](LICENSE)
