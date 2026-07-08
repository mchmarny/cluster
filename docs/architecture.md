# Architecture

Provider-generic architecture and design concepts for the Cluster toolkit.

## Project Layout

```
cmd/cluster/          Go CLI entrypoint
pkg/                  Go packages (aws, azure, gcp, oci, cluster, config, run, state, terraform)
provider/eks/         EKS Terraform + tools (actuate, setup, validate, disco)
provider/gke/         GKE Terraform + tools (setup, disco, validate)
provider/aks/         AKS Terraform + tools (setup, disco, validate)
config/               Global config files (provider-prefixed: eks-*.yaml, gke-*.yaml, aks-*.yaml)
schema/               JSON Schema for config validation
image/                Dockerfiles (eks.dockerfile, gke.dockerfile, aks.dockerfile)
tools/                Shared scripts (common, mirror, e2e, check-tools)
.settings.yaml        Single source of truth for versions
```

## Configuration-Driven Design

All infrastructure values flow through a single path:

```
YAML config -> yamldecode() -> locals {} -> resources
```

Each platform's `terraform/main.tf` loads the YAML file via `yamldecode(file(var.CONFIG_PATH))`, extracts values through a `locals {}` block using `try()` for optional fields with defaults, and feeds them into resources. Nothing is hardcoded.

Config is passed to Terraform via `TF_VAR_CONFIG_PATH="$CONFIG_FILE"`.

A [JSON Schema](../schema/cluster-config.schema.json) is provided for editor autocomplete (e.g. Red Hat YAML extension for VS Code).

### Configuration Schema

Shared top-level structure; provider-specific fields nest under the provider key, e.g. `cluster.gke`/`cluster.eks`/`cluster.aks` and the matching `compute.<provider>`.

```yaml
deployment:
  id: <string>           # Deployment identifier (required)
  provider: <string>     # eks | gke | aks (required)
  tenancy: <string>      # Account/Project ID (required)
  location: <string>     # Region (required)
  state: tenancy         # tenancy (cloud) | local (tfstate)
  destroy: false         # Set true to destroy
  tags: {}               # Resource tags (optional)

# EKS
cluster:
  name: <string>         # Cluster name (defaults to deployment.id)
  version: <string>      # K8s version (required)
  addOns:                # Optional EKS add-ons
    vpcCni: ""           # Enables custom networking (secondary CIDR, pod subnets, ENIConfig)
compute:
  nodeGroups:            # system + workers with instanceType, capacity

# GKE
cluster:
  gke:
    version: <string>    # K8s version (null = latest in release channel)
    releaseChannel: STABLE
    controlPlane:
      authorizedNetworks: []
compute:
  gke:
    nodePools:           # system + workers with machineType, guestAccelerator, zones

network:                 # Optional -- auto-computed from VPC CIDR for both providers
```

The `init` command generates the appropriate template based on the output filename prefix (`gke-*`, `aks-*` produce their respective templates; anything else produces EKS).

### CLI Commands

| Command | Description |
|---------|-------------|
| `init <path>` | Generate a starter configuration file |
| `plan -c <config>` | Show Terraform plan output without applying |
| `apply -c <config>` | Deploy or destroy infrastructure via Terraform |
| `output -c <config>` | Retrieve Terraform outputs and save to state directory |

## Node Pool Separation

Every cluster uses two pool tiers:

- **System pools** -- run cluster-critical workloads (CoreDNS, metrics-server, etc.). Tainted with `dedicated=system-workload:NoSchedule,NoExecute` so user pods cannot land here.
- **Worker pools** -- run application workloads. Tainted with `dedicated=worker-workload:NoSchedule,NoExecute`. Optional; a system-only cluster is valid.

This separation ensures control plane components are isolated from user workload resource pressure.

## State Management

State storage is controlled by `deployment.state`:

| Value | Backend | Location |
|-------|---------|----------|
| `tenancy` (default) | Cloud object store | S3 (EKS), GCS (GKE), or Azure Blob (AKS), keyed by `deployments/{region}/{id}/terraform.tfstate` |
| `local` | Local filesystem | `terraform.tfstate` in the working directory |

The `tenancy` mode provisions a per-tenancy state container with versioning and
restricted access: `cluster-state-{account-or-project-id}` for EKS/GKE and a
`clst{subscription-hex}` Storage Account (`tfstate` container) for AKS.

## Container Images

Each platform has a self-contained Docker image (`image/<csp>.dockerfile`) that includes:

- The `cluster` Go binary as entrypoint
- Pre-mirrored Terraform providers for offline deployment
- All required Terraform configuration

Images are multi-arch (amd64 + arm64), built on native runners (no QEMU).

| Platform | Image |
|----------|-------|
| EKS | `ghcr.io/mchmarny/cluster/eks:<version>` |
| GKE | `ghcr.io/mchmarny/cluster/gke:<version>` |
| AKS | `ghcr.io/mchmarny/cluster/aks:<version>` |

### Building Images

```bash
make build-eks   # Mirror providers + build EKS image
make build-gke   # Mirror providers + build GKE image
make build-aks   # Mirror providers + build AKS image
```

Tags matching `v*-eks`, `v*-gke`, or `v*-aks` pushed to `main` trigger CI builds.

## GKE: GPU Multi-NIC Networking

Optional support for multi-NIC GPU networking (GPUDirect-TCPXO) on instances like `a3-megagpu-8g`, driven by the `network.gke.gpuNets` config block.

- **Separate VPCs per GPU NIC** -- creates dedicated VPC networks for each GPU NIC plus a gVNIC network, with their own subnets and firewall rules.
- **Cluster flags** -- auto-enables `enable_multi_networking` on the cluster and activates Kubernetes beta APIs for Dynamic Resource Allocation (DRA).
- **Post-deploy CRDs** -- generates and applies `Network` and `GKENetworkParamSet` custom resources to wire GPU NICs into the cluster networking layer.
- **Conditional** -- only activates when `gpuNets.count > 0`. CPU-only clusters are unaffected.

## EKS: EFA Networking

EFA (Elastic Fabric Adapter) support for GPU instances uses dynamic network card count discovery. The EFA network card count is determined automatically from instance type metadata rather than being hardcoded, ensuring correct configuration across different instance types (e.g., `p5.48xlarge`, `p4d.24xlarge`).

## Security Model

### Private by Default

- **Private API endpoints** -- cluster control plane is not publicly accessible by default
- **Authorized networks** -- only explicitly allowed CIDRs can reach the API server
- **Workload identity** -- pods authenticate via IRSA (EKS), Workload Identity (GKE), or Entra Workload Identity (AKS), no static secrets

### Account Validation

Each platform's Terraform includes a `lifecycle` precondition on the base network resource that verifies the active cloud account/subscription/tenancy matches the config's `deployment.tenancy`. This halts the apply on a mismatch, preventing cross-account deployment mistakes.

### Encryption

All platforms encrypt secrets, volumes, and logs at rest using provider-managed or customer-managed keys.

## Version Management

`.settings.yaml` is the single source of truth for all tool versions and build configuration. It is consumed by:

- **Makefile** -- via `yq -r` with fallback defaults
- **GitHub Actions** -- via `.github/actions/load-versions` composite action
- **`tools/check-tools`** -- compares installed vs expected versions

When updating tool versions, change `.settings.yaml` only. Makefile, CI, and Dockerfiles pick it up automatically.
