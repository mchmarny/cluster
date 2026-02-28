# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Multi-cloud Kubernetes cluster deployment toolkit. Provides Terraform configurations with YAML-driven customization for EKS (AWS) and GKE (Google Cloud).

## Version Management

`.settings.yaml` is the **single source of truth** for all tool versions and build configuration. It is consumed by:
- **Makefile** — via `yq -r` with fallback defaults
- **GitHub Actions** — via `.github/actions/load-versions` composite action
- **`tools/check-tools`** — compares installed vs expected versions

When updating tool versions, change `.settings.yaml` only — Makefile, CI, and Dockerfiles pick it up automatically.

## Build Commands

### Quality Checks (root Makefile)
```bash
make qualify      # Run all quality checks (Go + Terraform)
make go-qualify   # Go: vet, fmt, lint, test, build
make tf-qualify   # Terraform: validate, lint, fmt, trivy scan
make go-test      # Unit tests with race detection and coverage
make tools-check  # Verify tools installed and compare versions to .settings.yaml
make e2e          # Full end-to-end (qualify + Docker build + smoke tests)
```

### Image Builds
```bash
make build-eks    # Mirror providers + build EKS Docker image
make build-gke    # Mirror providers + build GKE Docker image
```

### Go CLI Commands (inside container)
The `cluster` binary exposes three commands:
- `cluster init <path>` — generate starter config
- `cluster setup -c <config>` — bootstrap cloud account (S3 bucket, IAM user, key)
- `cluster apply -c <config>` — deploy or destroy via Terraform (destroy when `deployment.destroy: true`)

### Local Provider Tools
EKS-specific shell scripts in `provider/eks/tools/`:
```bash
provider/eks/tools/actuate -c config/eks-demo.yaml apply    # plan + apply
provider/eks/tools/setup -c config/eks-demo.yaml            # bootstrap AWS
provider/eks/tools/validate -c config/eks-demo.yaml         # post-deploy checks
provider/eks/tools/disco -r us-west-2                       # discover versions
```
All scripts source `tools/common` for shared logging, config resolution, and terraform helpers.

## Architecture

### Project Layout
```
cmd/cluster/          # Go CLI entrypoint
pkg/                  # Go packages (aws, cluster, config, run, state, terraform)
provider/eks/         # EKS Terraform + tools
provider/gke/         # GKE Terraform + tools
config/               # Global config files (provider-prefixed: eks-demo.yaml, gke-demo.yaml)
schema/               # JSON Schema for config validation
image/                # Dockerfiles (eks.dockerfile, gke.dockerfile)
tools/                # Shared scripts (common, mirror, e2e, check-tools)
.settings.yaml        # Single source of truth for versions
```

### Terraform Module Convention (per platform)
Each platform (`provider/eks/`, `provider/gke/`) has `terraform/` with:
- **variables.tf**: Single variable `CONFIG_PATH`
- **main.tf**: `yamldecode(file(var.CONFIG_PATH))` loads YAML, then `locals {}` block extracts all values with `try()` for optional fields with defaults. Includes `check` block to validate account/project matches config.
- **cluster.tf**: Managed K8s cluster resource
- **compute.tf**: Node pools (system + worker) with autoscaling
- **network.tf**: VPC/VNet, subnets, NAT, routing
- **iam.tf**: Identities, service accounts, workload identity federation
- **outputs.tf**: Writes `<config-basename>-status.json` alongside config file

Config is passed to Terraform via `TF_VAR_CONFIG_PATH="$CONFIG_FILE"`.

### Container Images
Built from `image/<csp>.dockerfile`. Include pre-mirrored Terraform providers for offline deployment. Multi-arch (amd64 + arm64) via native runners (no QEMU). Entrypoint is the `cluster` Go binary.

## Key Patterns

**Configuration-Driven**: All infrastructure values flow from YAML → `yamldecode()` → `locals {}` → resources. Never hardcode.

**Private by Default**: Private API endpoints, authorized networks, workload identity (no secrets in pods).

**Node Pool Separation**: System pools (with `dedicated=system-workload` taints) for control plane components; worker pools for user workloads.

**Account Validation**: Terraform `check` blocks verify the active cloud account matches config's `deployment.tenancy` to prevent cross-account mistakes.

**AWS helpers in pkg/aws**: Provider-specific functions like `BucketName()`, `PolicyARN()`, `SAName()` live in `pkg/aws`, not on the generic `Config` struct.

## Behavioral Guidelines

- Be explicit and literal; state uncertainty when present
- Identify edge cases, failure modes, and operational risks
- If critical inputs are missing (SLOs, consistency requirements, failure domains), ask before designing

## Rules

1. **Read before writing** — Never modify code you haven't read
2. **Use project patterns** — Study existing code in same package before inventing new approaches
3. **Implement what's asked** — No unrequested features or refactoring
4. **Fix, don't skip** — Never disable tests to make CI pass
5. **Edit over Write** — Prefer editing existing files to creating new ones
6. **3-strike rule** — After 3 failed fix attempts, stop, reassess, and explain blockers
7. **No plans in repo** — Store Claude plans/designs in `/tmp`, never commit to the repository
