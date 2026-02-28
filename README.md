# Cluster

Opinionated Kubernetes cluster deployment toolkit. Provides Terraform configurations with sensible defaults and YAML-based customization for EKS (AWS) and GKE (Google Cloud).

## Platforms

| Platform | Directory | Features |
|----------|-----------|----------|
| [AWS (EKS)](./provider/eks/) | `provider/eks/` | Multi-AZ, VPC CNI, self-managed nodes, CloudWatch |
| [Google Cloud (GKE)](./provider/gke/) | `provider/gke/` | Regional cluster, Workload Identity, Shielded Nodes |

## Quick Start

### 1. Prerequisites

```bash
terraform --version  # >= 1.14
yq --version         # YAML processor
aws --version        # AWS CLI (for EKS)
gcloud --version     # GCP CLI (for GKE)
```

### 2. Generate Config

```shell
docker run --rm \
  -v $PWD/config:/config \
  ghcr.io/mchmarny/cluster/eks:latest init /config/eks-example.yaml
```

Or use an existing example:

**EKS** (`config/eks-minimal.yaml`):
```yaml
deployment:
  id: demo
  provider: eks
  tenancy: "123456789012"
  location: us-east-1

cluster:
  name: demo
  version: "1.33"
  controlPlane:
    allowedCidrs:
      - 1.2.3.4/32

compute:
  nodeGroups:
    system:
      instanceType: m6i.xlarge
      capacity:
        desired: 3
```

**GKE** (`config/gke-minimal.yaml`):
```yaml
deployment:
  id: demo
  provider: gke
  tenancy: "my-project-id"
  location: us-central1

cluster:
  controlPlane:
    authorizedNetworks:
      - cidr: 1.2.3.4/32
        name: my-network
```

### 3. Deploy

See [DEMO.md](DEMO.md) for the full init → setup → apply workflow.

## Container Images

Self-contained actuator images with pre-mirrored Terraform providers. Multi-arch (amd64 + arm64) built on native runners.

| Platform | Image |
|----------|-------|
| EKS | `ghcr.io/mchmarny/cluster/eks:<version>` |
| GKE | `ghcr.io/mchmarny/cluster/gke:<version>` |

### CLI Commands

| Command | Description |
|---------|-------------|
| `init <path>` | Generate a starter configuration file |
| `setup -c <config>` | Bootstrap cloud account (state bucket, IAM user, access key) |
| `apply -c <config>` | Deploy or destroy infrastructure via Terraform |

Destroy is triggered by setting `deployment.destroy: true` in the config and running `apply`.

### Configuration Input

| Method | Flag / Env Var | Description |
|--------|---------------|-------------|
| File path | `-c` / `CONFIG_PATH` | Path to YAML config file |
| Base64 content | `CONFIG_CONTENT` | Base64-encoded YAML |

### Building Images

```bash
make build-eks   # Mirror providers + build EKS image
make build-gke   # Mirror providers + build GKE image
```

Tags matching `v*-eks` or `v*-gke` pushed to `main` trigger CI builds.

## Configuration Schema

A [JSON Schema](schema/cluster-config.schema.json) is provided for VS Code autocomplete (Red Hat YAML extension).

```yaml
deployment:
  id: <string>           # Deployment identifier (required)
  provider: <string>     # eks | gke (required)
  tenancy: <string>      # Account/Project ID (required)
  location: <string>     # Region (required)
  state: tenancy         # tenancy (cloud) | local (tfstate)
  destroy: false         # Set true to destroy
  tags: {}               # Resource tags

cluster:
  name: <string>         # Cluster name (required)
  version: <string>      # K8s version (required)

network:                 # Optional — auto-computed from VPC CIDR
compute:                 # Optional — system + worker node groups
```

## Development

```bash
make qualify      # All quality checks (Go + Terraform)
make go-qualify   # Go: vet, fmt, lint, test, build
make tf-qualify   # Terraform: validate, lint, fmt, trivy scan
make e2e          # Full end-to-end (qualify + Docker build + smoke tests)
make tools-check  # Verify tool versions match .settings.yaml
```

## License

MIT — see [LICENSE](LICENSE)
