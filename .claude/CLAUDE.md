# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Multi-cloud Kubernetes cluster deployment toolkit. Provides Terraform configurations with YAML-driven customization for AKS (Azure), EKS (AWS), GKE (Google Cloud), OKE (Oracle Cloud), and KinD (local dev).

## Build Commands

### Validation (root Makefile)
```bash
make all          # Run all checks: tf-validate, tf-lint, tf-fmt, scan
make tf-init      # Init Terraform in all directories (plugin cache: ~/.terraform.d/plugin-cache)
make tf-validate  # Validate Terraform configs (runs tf-init first)
make tf-fmt       # Check formatting
make tf-lint      # Run tflint (uses .tflint.hcl with aws + google plugins)
make scan         # Trivy security scan (CRITICAL,HIGH; uses .trivyignore)
make dep-check    # Verify terraform, tflint, trivy are installed
```

### Platform Deployment (from platform directory: aks/, eks/, gke/, oke/)
Two scripts per platform — both in `<platform>/tools/`:

**Platform-specific `actuate`** (direct local deployment):
```bash
./tools/setup configs/demo.yaml          # Create backend state storage
./tools/actuate configs/demo.yaml        # Plan + apply (takes config path as positional arg)
```
Set `deployment.destroy: true` in YAML config to destroy instead of apply.

**Shared `tools/actuate`** (container/CI deployment, at repo root):
```bash
./tools/actuate -c configs/demo.yaml plan      # plan | apply | destroy | output
./tools/actuate -c configs/demo.yaml -a apply  # -a = auto-approve
```
Also accepts config via env vars: `CONFIG_PATH`, `CONFIG_CONTENT` (base64), `CONFIG_URL` (s3/gs/https/az/oci), `CONFIG_JSON`.

### KinD Local Development
```bash
cd kind && make cluster-up    # CLUSTER_NAME=demo, NODE_IMAGE=kindest/node:v1.32.2
cd kind && make cluster-down
```

## Architecture

### Two Layers of Tooling

1. **Platform-specific scripts** (`<platform>/tools/actuate`, `setup`, `common`): Used for direct local deployment. The `actuate` script sources `common` for shared helpers (msg/warn/err, has_tools, validate_config, config_get). Each reads the YAML config, extracts deployment settings, initializes Terraform backend, and runs plan+apply.

2. **Shared container actuator** (`tools/actuate`): Used inside Docker images for CI/CD. Auto-detects CSP from Terraform resource names (e.g., `aws_eks_cluster` → EKS). Handles multi-source config resolution. Images built via `.github/workflows/build-actuator.yml` on `v*-<csp>` tags with pre-mirrored providers (`tools/mirror`).

### Terraform Module Convention (per platform)
Each platform (`aks/`, `eks/`, `gke/`, `oke/`) has `terraform/` with:
- **variables.tf**: Single variable `CONFIG_PATH`
- **main.tf**: `yamldecode(file(var.CONFIG_PATH))` loads YAML, then `locals {}` block extracts all values with `try()` for optional fields with defaults. Includes `check` block to validate account/subscription/project matches config.
- **cluster.tf**: Managed K8s cluster resource
- **compute.tf**: Node pools (system + worker) with autoscaling
- **network.tf**: VPC/VNet, subnets, NAT, routing
- **iam.tf**: Identities, service accounts, workload identity federation
- **outputs.tf**: Writes `<config-basename>-status.json` alongside config file

Config is passed to Terraform via `TF_VAR_CONFIG_PATH="$CONFIG_FILE"`.

### Adding/Modifying Terraform Resources
When working on a platform's Terraform:
- All values must come from `local.*` (defined in main.tf) — never hardcode
- Optional config fields use `try(local.config.path.to.field, default_value)`
- Subnets are auto-computed from VPC CIDR if not specified in config
- Egress IP is auto-detected via HTTP lookup for authorized network rules
- Tags are applied from `local.effective_tags` (from `deployment.tags`)

### Container Images
Built from `images/<csp>.dockerfile`. Include pre-mirrored Terraform providers for offline deployment. Multi-arch (amd64 + arm64). Entrypoint is the shared `tools/actuate`.

## Key Patterns

**Configuration-Driven**: All infrastructure values flow from YAML → `yamldecode()` → `locals {}` → resources. Never hardcode.

**Private by Default**: Private API endpoints, authorized networks, workload identity (no secrets in pods).

**Node Pool Separation**: System pools (with `dedicated=system-workload` taints) for control plane components; worker pools for user workloads.

**Account Validation**: Terraform `check` blocks verify the active cloud account matches config's `deployment.tenancy` to prevent cross-account mistakes.

**Status Output**: Deployment results written as JSON to `<config-basename>-status.json` in same directory as config.

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
