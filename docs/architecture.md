# Architecture

Provider-generic architecture and design concepts for the Cluster toolkit.

## Project Layout

```
cmd/cluster/          Go CLI entrypoint
pkg/                  Go packages (aws, cluster, config, run, state, terraform)
provider/eks/         EKS Terraform + tools (actuate, setup, validate, disco)
provider/gke/         GKE Terraform + tools (setup, disco, validate)
config/               Global config files (provider-prefixed: eks-demo.yaml, gke-demo.yaml)
schema/               JSON Schema for config validation
image/                Dockerfiles (eks.dockerfile, gke.dockerfile)
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

```yaml
deployment:
  id: <string>           # Deployment identifier (required)
  provider: <string>     # eks | gke (required)
  tenancy: <string>      # Account/Project ID (required)
  location: <string>     # Region (required)
  state: tenancy         # tenancy (cloud) | local (tfstate)
  destroy: false         # Set true to destroy
  tags: {}               # Resource tags (optional)

cluster:
  name: <string>         # Cluster name (defaults to deployment.id)
  version: <string>      # K8s version (required)
  addOns:                # Optional EKS add-ons
    vpcCni: ""           # Enables custom networking (secondary CIDR, pod subnets, ENIConfig)

network:                 # Optional -- auto-computed from VPC CIDR
                         # Pod CIDR/subnets only apply when vpcCni is enabled
compute:                 # Optional -- system + worker node groups
```

## Node Pool Separation

Every cluster uses two pool tiers:

- **System pools** -- run cluster-critical workloads (CoreDNS, metrics-server, etc.). Tainted with `dedicated=system-workload:NoSchedule,NoExecute` so user pods cannot land here.
- **Worker pools** -- run application workloads. Tainted with `dedicated=worker-workload:NoSchedule,NoExecute`. Optional; a system-only cluster is valid.

This separation ensures control plane components are isolated from user workload resource pressure.

## State Management

State storage is controlled by `deployment.state`:

| Value | Backend | Location |
|-------|---------|----------|
| `tenancy` (default) | Cloud object store | S3 (EKS) or GCS (GKE), keyed by `deployments/{region}/{id}/terraform.tfstate` |
| `local` | Local filesystem | `terraform.tfstate` in the working directory |

The `tenancy` mode creates a bucket named `cluster-state-{account-or-project-id}` with versioning, encryption, and public access blocking.

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

### Building Images

```bash
make build-eks   # Mirror providers + build EKS image
make build-gke   # Mirror providers + build GKE image
```

Tags matching `v*-eks` or `v*-gke` pushed to `main` trigger CI builds.

## Security Model

### Private by Default

- **Private API endpoints** -- cluster control plane is not publicly accessible by default
- **Authorized networks** -- only explicitly allowed CIDRs can reach the API server
- **Workload identity** -- pods authenticate via IRSA (EKS) or Workload Identity (GKE), no static secrets

### Account Validation

Each platform's Terraform includes a `check` block that verifies the active cloud account/project matches the config's `deployment.tenancy`. This prevents cross-account deployment mistakes.

### Encryption

All platforms encrypt secrets, volumes, and logs at rest using provider-managed or customer-managed keys.

## Version Management

`.settings.yaml` is the single source of truth for all tool versions and build configuration. It is consumed by:

- **Makefile** -- via `yq -r` with fallback defaults
- **GitHub Actions** -- via `.github/actions/load-versions` composite action
- **`tools/check-tools`** -- compares installed vs expected versions

When updating tool versions, change `.settings.yaml` only. Makefile, CI, and Dockerfiles pick it up automatically.
