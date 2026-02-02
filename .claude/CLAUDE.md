# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a Kubernetes cluster deployment toolkit providing production-ready Terraform configurations for deploying managed Kubernetes clusters across Azure (AKS), AWS (EKS), Google Cloud (GKE), Oracle Cloud (OKE), and local development (KinD).

## Build Commands

### Root Makefile
```bash
make all          # Run all validation checks (validate, lint, fmt, scan)
make tf-init      # Initialize Terraform in all directories with plugin caching
make tf-validate  # Validate Terraform configuration
make tf-fmt       # Check Terraform formatting
make tf-lint      # Run tflint static analysis
make scan         # Run Trivy security scanning (CRITICAL,HIGH)
make dep-check    # Verify required tools (terraform, tflint, trivy)
```

### Platform Deployment (AKS/EKS/GKE/OKE)
Each platform uses the same workflow via `tools/actuate`:
```bash
# Setup backend storage for Terraform state
./tools/setup -c configs/demo.yaml

# Deployment commands
./tools/actuate -c configs/demo.yaml plan      # Generate execution plan
./tools/actuate -c configs/demo.yaml apply     # Apply infrastructure
./tools/actuate -c configs/demo.yaml destroy   # Destroy infrastructure
./tools/actuate -c configs/demo.yaml output    # Show deployment outputs

# Options: -a (auto-approve), -v (verbose)
```

### KinD Local Development
```bash
cd kind
make cluster-up    # Create local cluster (CLUSTER_NAME=demo by default)
make cluster-down  # Delete cluster
```

## Architecture

### Directory Structure Pattern
Each cloud platform (`aks/`, `eks/`, `gke/`, `oke/`) follows identical structure:
```
<platform>/
├── configs/        # YAML configuration examples
├── terraform/      # Terraform modules (main, cluster, compute, network, iam, outputs)
└── tools/          # Bash scripts (actuate, setup, common)
```

### Terraform Module Design
- **main.tf**: Loads YAML config via `yamldecode()`, defines all local variables
- **cluster.tf**: Managed Kubernetes cluster resource
- **compute.tf**: Node pools (system + worker) with autoscaling
- **network.tf**: VPC/VNet, subnets, security groups, NAT
- **iam.tf**: Managed identities, service accounts, workload identity
- **outputs.tf**: Deployment info and status JSON generation
- **variables.tf**: Single `CONFIG_PATH` variable pointing to YAML config

### Configuration System
All infrastructure is driven by YAML configuration files. Key sections:
- `deployment`: Cloud provider, region, tags
- `cluster`: K8s version, features (OIDC, workload identity)
- `network`: CIDR ranges, network plugin, subnets
- `compute.nodePools`: System and worker node specifications
- `security`: RBAC, network policies, defender settings
- `iam.workloadIdentities`: Federated credential bindings

## Tool Requirements

- Terraform >= 1.13.0
- tflint (configured via .tflint.hcl)
- Trivy (security scanner)
- yq, jq (YAML/JSON processing)
- Platform CLIs: az (Azure), aws (AWS), gcloud (GCP), oci (Oracle)
- kubectl, docker

## Key Patterns

**Configuration-Driven**: Never hardcode infrastructure values. All settings flow from YAML configs through Terraform locals.

**Workload Identity**: All platforms support federated credentials for pod-to-cloud-service authentication without secrets.

**Private Clusters**: Default security posture is private API endpoints with authorized networks.

**Node Pool Separation**: System pools run control plane components; worker pools run user workloads.

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
