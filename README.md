# Cluster

Opinionated Kubernetes cluster deployment toolkit for multiple cloud platforms. Provides Terraform configurations with sensible defaults and YAML-based customization.

## Platforms

| Platform | Directory | Features |
|----------|-----------|----------|
| [Azure (AKS)](./aks/) | `aks/` | Private cluster, Workload Identity, Key Vault CSI, Azure CNI |
| [AWS (EKS)](./eks/) | `eks/` | Multi-AZ, VPC CNI, self-managed nodes, CloudWatch |
| [Google Cloud (GKE)](./gke/) | `gke/` | Regional cluster, Workload Identity, Shielded Nodes |
| [Oracle Cloud (OKE)](./oke/) | `oke/` | VCN-native networking, Flex shapes, GPU support |
| [Local (KinD)](./kind/) | `kind/` | Development and testing |

## Quick Start

### 1. Prerequisites

```bash
# Required tools
terraform --version  # >= 1.13.0
yq --version         # YAML processor

# Platform CLI (one of)
az --version         # Azure
aws --version        # AWS
gcloud --version     # GCP
oci --version        # Oracle
```

### 2. Minimal Configuration

Each platform supports minimal configs that rely on sensible defaults:

**AKS** (`aks/configs/minimal.yaml`):
```yaml
deployment:
  id: demo
  tenancy: "00000000-0000-0000-0000-000000000000"  # Subscription ID
  location: eastus
  azure:
    resourceGroup: "rg-aks-demo"

cluster:
  controlPlane:
    authorizedIpRanges:
      - 1.2.3.4/32  # Your IP
```

**EKS** (`eks/configs/minimal.yaml`):
```yaml
deployment:
  id: demo
  tenancy: "123456789012"  # Account ID
  location: us-east-1

cluster:
  controlPlane:
    allowedCidrs:
      - 1.2.3.4/32

compute:
  sshPublicKey: "ssh-ed25519 AAAA..."
  nodeGroups:
    system:
      instanceType: m6i.xlarge
      imageId: ami-0b72f4a84c39bcd30
```

**GKE** (`gke/configs/minimal.yaml`):
```yaml
deployment:
  id: demo
  tenancy: "my-project-id"  # Project ID
  location: us-central1

cluster:
  controlPlane:
    authorizedNetworks:
      - cidr: 1.2.3.4/32
        name: my-network
```

**OKE** (`oke/configs/minimal.yaml`):
```yaml
deployment:
  id: demo
  tenancy: "ocid1.tenancy.oc1..XXX"
  location: us-ashburn-1
  oci:
    compartment: "ocid1.compartment.oc1..XXX"

cluster:
  controlPlane:
    allowedCidrs:
      - 1.2.3.4/32

compute:
  sshPublicKey: "ssh-ed25519 AAAA..."
```

### 3. Deploy

```bash
cd <platform>  # aks, eks, gke, or oke

# Setup backend storage for Terraform state
./tools/setup configs/minimal.yaml

# Deploy cluster
./tools/actuate configs/minimal.yaml
```

## Container Images

Self-contained actuator images with pre-mirrored Terraform providers are built automatically on tag push. These images enable offline, reproducible deployments without runtime dependency downloads.

### Available Images

| Platform | Image |
|----------|-------|
| EKS | `ghcr.io/mchmarny/cluster/eks:<version>` |
| GKE | `ghcr.io/mchmarny/cluster/gke:<version>` |
| AKS | `ghcr.io/mchmarny/cluster/aks:<version>` |
| OKE | `ghcr.io/mchmarny/cluster/oke:<version>` |

### Building Images

Images are built automatically when tags matching `v*-<csp>` are pushed:

```bash
# Tag and push to trigger build
git tag v1.0.0-eks
git push origin v1.0.0-eks
```

### Configuration Methods

The actuator supports multiple configuration input methods (in priority order):

| Priority | Method | Environment Variable | Description |
|----------|--------|---------------------|-------------|
| 1 | File path | `CONFIG_PATH` | Path to YAML config file |
| 2 | Base64 content | `CONFIG_CONTENT` | Base64-encoded YAML |
| 3 | Remote URL | `CONFIG_URL` | S3, GCS, HTTPS, Azure, OCI URLs |
| 4 | Inline JSON | `CONFIG_JSON` | JSON converted to YAML |

### Usage Examples

**Docker with base64 config:**
```bash
docker run \
  -e CONFIG_CONTENT="$(base64 < config.yaml)" \
  -e AUTO_APPROVE=true \
  -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  ghcr.io/mchmarny/cluster/eks:v1.0.0 apply
```

**Docker with mounted config:**
```bash
docker run \
  -v $(pwd)/config.yaml:/config.yaml \
  -e CONFIG_PATH=/config.yaml \
  -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  ghcr.io/mchmarny/cluster/eks:v1.0.0 plan
```

**Docker with remote config (S3):**
```bash
docker run \
  -e CONFIG_URL=s3://my-bucket/configs/prod.yaml \
  -e AWS_ACCESS_KEY_ID="$AWS_ACCESS_KEY_ID" \
  -e AWS_SECRET_ACCESS_KEY="$AWS_SECRET_ACCESS_KEY" \
  ghcr.io/mchmarny/cluster/eks:v1.0.0 apply
```

**Kubernetes Job:**
```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: cluster-deploy
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: actuator
          image: ghcr.io/mchmarny/cluster/eks:v1.0.0
          args: ["apply"]
          env:
            - name: CONFIG_CONTENT
              valueFrom:
                secretKeyRef:
                  name: cluster-config
                  key: config.yaml.b64
            - name: AUTO_APPROVE
              value: "true"
            - name: AWS_ACCESS_KEY_ID
              valueFrom:
                secretKeyRef:
                  name: aws-credentials
                  key: access-key-id
            - name: AWS_SECRET_ACCESS_KEY
              valueFrom:
                secretKeyRef:
                  name: aws-credentials
                  key: secret-access-key
```

### Commands

| Command | Description |
|---------|-------------|
| `plan` | Generate and show execution plan |
| `apply` | Apply the Terraform configuration (default) |
| `destroy` | Destroy the infrastructure |
| `output` | Show deployment outputs |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `CONFIG_PATH` | Path to YAML configuration file |
| `CONFIG_CONTENT` | Base64-encoded YAML configuration |
| `CONFIG_URL` | Remote URL (s3://, gs://, https://, az://, oci://) |
| `CONFIG_JSON` | Inline JSON configuration |
| `AUTO_APPROVE` | Set to "true" to skip interactive approval |
| `TERRAFORM_DIR` | Override Terraform directory (default: /builder/terraform) |

## Configuration Schema

All platforms use a unified YAML configuration schema:

```yaml
deployment:
  id: <string>           # Deployment identifier (required)
  tenancy: <string>      # Account/Subscription/Project ID (required)
  location: <string>     # Region (required)
  tags: {}               # Resource tags (optional)
  # Platform-specific:
  azure:
    resourceGroup: <string>
  oci:
    compartment: <string>

cluster:
  name: <string>         # Cluster name (default: {id}-{platform})
  version: <string>      # K8s version (default: latest stable)
  controlPlane:
    authorizedIpRanges: []  # API access CIDRs (required)

network:                 # Optional - uses sensible defaults
  # Auto-computed if not specified:
  # - VPC CIDR: 10.0.0.0/16
  # - Subnet CIDRs: derived from VPC
  # - Pod/Service CIDRs: platform defaults

compute:                 # Optional - uses sensible defaults
  nodePools:
    system: {}           # Default: 3 nodes, standard instance
    # workers: []        # Optional worker pools
```

## Defaults

Terraform applies these defaults when not specified in config:

| Setting | Default |
|---------|---------|
| VPC/VNet CIDR | `10.0.0.0/16` |
| Pod CIDR | `10.244.0.0/16` (AKS) or `100.65.0.0/16` (EKS/OKE) |
| Service CIDR | `172.20.0.0/16` |
| Private cluster | `true` |
| Workload Identity | `true` |
| System node pool | 3 nodes, autoscaling 2-10 |

## Development

```bash
# Validate all Terraform
make all

# Individual checks
make tf-validate  # Terraform validation
make tf-lint      # tflint analysis
make tf-fmt       # Format check
make scan         # Trivy security scan
```

## License

MIT - see [LICENSE](LICENSE)
