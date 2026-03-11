# Google GKE Cluster Builder

Deploys a production-ready GKE cluster from a single YAML config:

- Regional cluster with multi-zone node distribution
- VPC-native networking with secondary ranges for pods and services
- Private cluster with authorized networks for control plane access
- Workload Identity for secure pod-to-GCP service authentication
- KMS encryption, Shielded Nodes, and Cloud NAT
- Cloud Monitoring, Cloud Logging, and optional Managed Prometheus

---

## Deployment

### Prerequisites

- **gcloud CLI** configured with appropriate credentials
- **yq** >= 4.0 for YAML parsing

### 1. Generate Config (optional)

Generate a starter config, or copy from an existing example in `config/`. The `init` command detects the provider from the filename prefix (`gke-*` generates a GKE template):

```shell
docker run --rm \
  -v $PWD/config:/config \
  ghcr.io/mchmarny/cluster/gke:latest init /config/gke-example.yaml
```

### 2. Setup Tenancy (one-time)

Bootstrap the GCP project with state bucket, service account, and IAM bindings. Run as yourself with owner/editor credentials:

```shell
provider/gke/tools/setup -c config/gke-example.yaml
```

This creates:
- GCS state bucket `cluster-state-{project-id}` with versioning
- Service account with required IAM roles (compute, container, KMS, logging, monitoring)
- Backend configuration for Terraform remote state

### 3. Apply

Deploy using the container image. `KEY_CONTENT` accepts a base64-encoded GCP ADC JSON (from `gcloud auth application-default login`):

```shell
docker run --rm \
  -e KEY_CONTENT="$(base64 < ~/.config/gcloud/application_default_credentials.json)" \
  -e CONFIG_CONTENT="$(base64 < config/gke-example.yaml)" \
  ghcr.io/mchmarny/cluster/gke:latest apply
```

Deployment time: approximately 10-15 minutes for full cluster creation.

### 4. Output (optional)

Retrieve deployment outputs (endpoint, access command, etc.) and save to the state volume:

```shell
docker run --rm \
  -v $PWD/state:/state \
  -e KEY_CONTENT="$(base64 < ~/.config/gcloud/application_default_credentials.json)" \
  -e CONFIG_CONTENT="$(base64 < config/gke-example.yaml)" \
  ghcr.io/mchmarny/cluster/gke:latest output
```

The output JSON is saved to `/state/{id}-{project}-output.json`.

### 5. Destroy

Set `deployment.destroy: true` in the config and re-run apply (step 3).

### Local Deployment (without container)

```shell
cluster apply -c config/gke-example.yaml
```

---

## Configuration Reference

### Config Tiers

#### Minimal

Subnets and secondary ranges are auto-computed from the VPC CIDR.

```yaml
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster

deployment:
  id: mini
  provider: gke
  tenancy: "my-gcp-project"
  location: us-west1
  state: tenancy

cluster:
  gke:
    version: "1.33"
    releaseChannel: STABLE

compute:
  gke:
    nodePools:
      system:
        machineType: e2-standard-4
      workers:
        - name: cpu-worker-1
          machineType: n2-standard-8
          labels:
            nodeGroup: cpu-worker
```

#### With authorized networks and custom node config

```yaml
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster

deployment:
  id: d1
  provider: gke
  tenancy: "my-project"
  location: europe-west4
  state: tenancy

cluster:
  gke:
    name: demo
    version: "1.33"
    releaseChannel: STABLE
    controlPlane:
      authorizedNetworks:
        - cidr: 1.2.3.0/27
          name: nyc-office
    maintenance:
      window:
        startTime: "03:00"

compute:
  gke:
    nodePools:
      system:
        machineType: e2-standard-4
        autoscaling:
          enabled: true
          minNodes: 1
          maxNodes: 3
      workers:
        - name: cpu-worker-1
          machineType: n2-standard-8
          diskType: pd-ssd
          diskSizeGb: 200
          autoscaling:
            enabled: true
            minNodes: 1
            maxNodes: 5
          nodeConfig:
            labels:
              nodeGroup: cpu-worker
```

#### With GPU worker pool

```yaml
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster

deployment:
  id: min-gpu
  provider: gke
  tenancy: "my-gcp-project"
  location: us-central1
  state: tenancy

cluster:
  gke:
    version: "1.35"
    controlPlane:
      authorizedNetworks:
        - cidr: 216.228.127.128/30
          name: office-vpn

network:
  gke:
    gpuNets:
      count: 8
      mtu: 8244
      cidrBase: "192.168.0.0/16"
      gvnicCidr: "192.168.128.0/20"
    firewallRules:
      - name: nccl-internal
        direction: INGRESS
        priority: 900
        sourceRanges:
          - "10.0.0.0/8"
        allowed:
          - protocol: tcp
          - protocol: udp
          - protocol: icmp

compute:
  gke:
    nodePools:
      system:
        machineType: e2-standard-4
      workers:
        - name: cpu-worker
          machineType: n2-standard-8
          diskType: pd-ssd
          nodeConfig:
            labels:
              nodeGroup: cpu-worker
        - name: gpu-worker
          machineType: a3-megagpu-8g
          diskType: pd-ssd
          zones:
            - us-central1-a
          guestAccelerator:
            type: nvidia-h100-mega-80gb
            count: 8
            gpuDriverInstallation:
              gpuDriverVersion: DEFAULT
          hostMaintenancePolicy:
            maintenanceInterval: PERIODIC
          nodeConfig:
            gvnic: true
            capacityReservations:
              - projects/my-project/reservations/my-reservation
            taints:
              - key: dedicated
                value: gpu-workload
                effect: NO_SCHEDULE
            labels:
              nodeGroup: gpu-worker
```

Notes:
- GPU machine types (e.g., `a3-megagpu-8g`) require `diskType: pd-ssd` — `pd-standard` is not compatible
- A3 High uses `nvidia-h100-mega-80gb` (not `nvidia-h100-80gb`)
- `hostMaintenancePolicy.maintenanceInterval: PERIODIC` is required for GPU nodes with capacity reservations
- Pin GPU pools to specific `zones` where the accelerator type is available
- `gpuDriverInstallation.gpuDriverVersion` controls driver version (`DEFAULT`, `LATEST`, or specific version)
- Capacity reservations go under `nodeConfig.capacityReservations`
- Taints under `nodeConfig.taints` with `key`, `value`, `effect` (`NO_SCHEDULE`, `NO_EXECUTE`, `PREFER_NO_SCHEDULE`)
- Verify GPU availability: `gcloud compute accelerator-types list --filter="zone:YOUR_REGION"`
- Your egress IP is automatically added to the API server authorized networks during deployment
- When `cluster.gke.version` is null, the latest version in the release channel is used

### GPU Multi-NIC Networking

The `network.gke.gpuNets` config enables dedicated GPU NIC networks for GPUDirect-TCPXO, used by A3 machine types for high-bandwidth inter-node GPU communication.

**Config fields** (`network.gke.gpuNets`):

| Field | Description |
|-------|-------------|
| `count` | Number of GPU NIC networks to create. Set to 8 for `a3-megagpu-8g`, 4 for `a3-highgpu-8g`. |
| `mtu` | MTU for all GPU and gVNIC networks (default: `8244`). |
| `cidrBase` | Base CIDR subdivided into `count` subnets (default: `10.0.32.0/16`). |
| `gvnicCidr` | CIDR for the dedicated gVNIC subnet (default: `10.0.16.0/20`). |
| `networkProfile` | GCP network profile for GPU VPCs (optional, null by default). |

**What gets created when enabled:**

1. **gVNIC network** -- dedicated VPC + subnet + internal firewall for high-bandwidth non-GPU traffic. Auto-created when `gpuNets.count > 0`.
2. **GPU NIC networks** -- N separate VPCs (one per NIC), each with a subnet and internal firewall allowing tcp/udp/icmp across all GPU subnets.
3. **K8s CRDs** -- `Network` and `GKENetworkParamSet` resources for each GPU NIC and gVNIC network, auto-applied to the cluster via a `local-exec` provisioner after deploy.

The CRD manifest is generated from `templates/gpu-net-config.ytpl` and written to `<config-basename>-gpu-net-config.yaml` alongside the config file.

**When to use:**

| Machine Type | GPU NIC Count | Accelerator |
|-------------|---------------|-------------|
| `a3-megagpu-8g` | 8 | `nvidia-h100-mega-80gb` |
| `a3-highgpu-8g` | 4 | `nvidia-h100-80gb` |

### Custom Firewall Rules

Optional custom firewall rules can be added under `network.gke.firewallRules`. Each rule specifies name, direction, priority, source ranges, and allowed protocols:

```yaml
network:
  gke:
    firewallRules:
      - name: nccl-internal
        direction: INGRESS
        priority: 900
        sourceRanges:
          - "10.0.0.0/8"
        allowed:
          - protocol: tcp
          - protocol: udp
          - protocol: icmp
```

Rules are created on the main VPC. This is useful for opening NCCL/RDMA ports across node subnets for distributed GPU training.

### File Layout

```
provider/gke/
  terraform/
    main.tf          # Config loading, locals, validation
    cluster.tf       # GKE cluster resource
    compute.tf       # Node pools (system + workers)
    network.tf       # VPC, subnets, NAT, firewall, GPU networks
    iam.tf           # Service accounts, IAM bindings
    outputs.tf       # Status JSON output
    variables.tf     # Single CONFIG_PATH variable
    templates/
      gpu-net-config.ytpl  # K8s CRD template for GPU multi-NIC
  tools/
    actuate          # Plan + apply wrapper
    setup            # Bootstrap GCP project
    common           # Shared shell functions
```

### Complete Config Reference

Every field Terraform reads, annotated with defaults. Omit any field to use its default.

```yaml
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster

deployment:
  id: ""                         # Required. Prefix for all GCP resources
  provider: gke                  # Required. Must be "gke"
  tenancy: ""                    # Required. GCP project ID
  location: ""                   # Required. GCP region
  state: tenancy                 # "tenancy" (GCS) or "local" (tfstate file)
  destroy: false                 # Set true to destroy all resources
  tags: {}                       # Key-value labels applied to all resources

cluster:
  gke:
    name: ""                     # Defaults to deployment.id
    version: ""                  # K8s version (null = latest in release channel)
    releaseChannel: STABLE       # RAPID, REGULAR, STABLE, or null
    deletionProtection: false    # Prevent accidental cluster deletion
    features:
      workloadIdentity: true
      gcpFilestoreCsiDriver: false
      gcsFuseCsiDriver: false
    private:
      enabled: true              # Private cluster with VPC peering
      masterIpv4CidrBlock: 172.16.0.0/28
    controlPlane:
      authorizedNetworks: []     # CIDRs allowed to access API server (egress IP auto-added)
    maintenance:
      window:
        startTime: "03:00"       # Daily maintenance window start (UTC)

security:
  binaryAuthorization:
    enabled: false
  secretsEncryption:
    enabled: true                # KMS encryption for cluster secrets
    preventDestroy: false        # Protect KMS key from accidental deletion
  shieldedNodes:
    secureBoot: true
    integrityMonitoring: true

network:
  gke:
    name: ""                     # Defaults to "<id>-vpc"
    cidr: 10.0.0.0/16           # VPC CIDR
    subnets:                     # Auto-computed from VPC CIDR if omitted
      nodes:
        - name: system-subnet
          cidr: 10.0.0.0/22
        - name: worker-subnet
          cidr: 10.0.128.0/17
      secondary:                 # Auto-computed if omitted
        system-subnet:
          pods:
            rangeName: system-pods
            cidr: 10.100.0.0/17
          services:
            rangeName: system-services
            cidr: 172.20.0.0/22
    nat:
      enabled: true
      sourceSubnetIpRangesToNat: ALL_SUBNETWORKS_ALL_IP_RANGES
      minPortsPerVm: 64
    gpuNets:                     # GPU multi-NIC networking (disabled by default)
      count: 0                   # Number of GPU NIC networks (8 for a3-megagpu-8g, 4 for a3-highgpu-8g)
      mtu: 8244                  # Jumbo frames for GPUDirect-TCPXO
      cidrBase: "10.0.32.0/16"  # Base CIDR for GPU networks (subdivided by count)
      gvnic: true                # Auto-enabled when gpuNets.count > 0
      gvnicCidr: "10.0.16.0/20" # Dedicated gVNIC subnet CIDR
      networkProfile: null       # GCP network profile (optional)
    firewallRules: []            # Custom firewall rules (optional array)
      # - name: nccl-internal
      #   direction: INGRESS
      #   priority: 900
      #   sourceRanges: ["10.0.0.0/8"]
      #   allowed:
      #     - protocol: tcp
      #     - protocol: udp

compute:
  gke:
    nodePools:
      system:                    # Runs cluster system components
        machineType: ""          # Required (e.g., e2-standard-4)
        imageType: COS_CONTAINERD
        diskType: pd-standard
        diskSizeGb: 100
        autoscaling:
          enabled: true
          minNodes: 1
          maxNodes: 3
          locationPolicy: BALANCED
        nodeConfig:
          preemptible: false
          spot: false
          labels: {}
          taints:                # Auto-applied: dedicated=CriticalAddonsOnly:NoSchedule
            - key: dedicated
              value: CriticalAddonsOnly
              effect: NO_SCHEDULE

      workers:                   # Application workload node pools
        - name: ""               # Required, unique per worker
          machineType: ""        # Required
          imageType: COS_CONTAINERD
          diskType: pd-standard  # Use pd-ssd for GPU machine types
          diskSizeGb: 100
          zones: []              # Restrict to specific zones (useful for GPU availability)
          guestAccelerator:      # GPU configuration (omit for CPU-only pools)
            type: ""             # e.g., nvidia-h100-80gb, nvidia-tesla-t4
            count: 0
          autoscaling:
            enabled: true
            minNodes: 1
            maxNodes: 3
            locationPolicy: BALANCED
          nodeConfig:
            preemptible: false
            spot: false
            labels: {}
            taints: []
            capacityReservations: []  # Specific reservation paths for GPU pools
```

### Defaults

| Setting | Default |
|---------|---------|
| Release channel | `STABLE` |
| VPC CIDR | `10.0.0.0/16` |
| System subnet | Auto-computed (`10.0.0.0/22`) |
| Worker subnet | Auto-computed (`10.0.128.0/17`) |
| Pod ranges | Auto-computed (system: `10.100.0.0/17`, worker: `10.100.128.0/17`) |
| Service ranges | Auto-computed |
| Master CIDR | `172.16.0.0/28` |
| Private cluster | `true` |
| Workload Identity | `true` |
| Shielded Nodes | `true` (secure boot + integrity monitoring) |
| Cloud NAT | `true` |
| Secrets encryption | `true` (KMS) |
| Node image type | COS_CONTAINERD |
| Node disk type | pd-standard |
| Node disk size | 100 GB |
| Autoscaling min | 1 |
| Autoscaling max | 3 |
| Location policy | BALANCED |
| NAT min ports/VM | 64 |
| Maintenance window | 03:00 UTC |
| GPU multi-NIC | Disabled (`gpuNets.count: 0`) |
| GPU NIC MTU | 8244 |
| GPU NIC CIDR base | `10.0.32.0/16` |
| gVNIC CIDR | `10.0.16.0/20` |
| Custom firewall rules | `[]` (none) |

---

## What Gets Created

| Category | Resources |
|----------|-----------|
| Network | VPC, system/worker subnets with secondary ranges, Cloud Router, Cloud NAT, custom firewall rules |
| GPU Network | (when `gpuNets` enabled) gVNIC VPC + subnet, N GPU VPCs + subnets, internal firewall rules, K8s Network + GKENetworkParamSet CRDs |
| Security | KMS key ring and crypto key for secrets encryption, firewall rules |
| GKE | Regional cluster, OIDC/Workload Identity, authorized networks |
| Compute | System node pool, worker node pools (CPU and/or GPU) |
| IAM | System node service account, worker node service account, IAM role bindings (logging, monitoring, KMS) |

---

## Troubleshooting

### API Not Enabled

```bash
gcloud services enable container.googleapis.com --project=PROJECT_ID
# Or re-run provider/gke/tools/setup
```

### Quota Exceeded

Check quotas and request increases in GCP Console:

```bash
gcloud compute project-info describe --project=PROJECT_ID
```

### Node Pool Creation Timeout

```bash
gcloud container node-pools list --cluster=CLUSTER_NAME --region=REGION
gcloud container operations list
```

### Pods Pending Due to Taints

System nodes have taints. Add tolerations to your pod spec:

```yaml
tolerations:
- key: "dedicated"
  operator: "Equal"
  value: "CriticalAddonsOnly"
  effect: "NoSchedule"
```

### Workload Identity Not Working

```bash
# Verify Workload Identity is enabled
gcloud container clusters describe CLUSTER_NAME --region=REGION \
  --format="value(workloadIdentityConfig.workloadPool)"

# Verify node pool metadata mode (should be GKE_METADATA)
gcloud container node-pools describe POOL_NAME \
  --cluster=CLUSTER_NAME --region=REGION \
  --format="value(config.workloadMetadataConfig.mode)"
```

### GPU Accelerator Not Available

GPU types have limited regional/zonal availability:

```bash
gcloud compute accelerator-types list --filter="zone:us-west1"
```

### Terraform State Lock

Previous deployment interrupted. Check GCS for stale lock files or wait for the other operation to complete.
