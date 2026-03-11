# Amazon EKS Cluster Builder

Deploys a production-ready EKS cluster from a single YAML config:

- Multi-AZ VPC with public, system, and worker subnets
- Optional VPC CNI custom networking (secondary CIDR for pod IPs) — enabled via `cluster.addOns.vpcCni`
- Self-managed worker node groups with EFA support for GPU instances
- EKS managed system node group with dedicated taints
- KMS encryption, VPC Flow Logs, and security group isolation
- CloudWatch observability, metrics server, and EBS CSI driver as opt-in add-ons

---

## Deployment

### Prerequisites

- **AWS CLI** >= 2.0 configured with appropriate credentials
- **yq** >= 4.0 for YAML parsing

### 1. Generate Config (optional)

Generate a starter config, or copy from an existing example in `config/`:

```shell
docker run --rm \
  -v $PWD/config:/config \
  ghcr.io/mchmarny/cluster/eks:latest init /config/eks-example.yaml
```

### 2. Discover Versions (optional)

Find latest K8s versions, add-on versions, and AMIs available in your region:

```shell
provider/eks/tools/disco -r us-east-1
```

This also prints your current IAM identity and role name for use in `cluster.adminRoles`.

### 3. Setup Tenancy (one-time)

Bootstrap the AWS account with state bucket, IAM user, and access key. Run as yourself with admin credentials:

```shell
provider/eks/tools/setup -c config/eks-example.yaml -o ./keys
```

This creates:
- S3 state bucket `cluster-state-{account-id}` with versioning and encryption
- IAM user, policy, and access key (saved to the output directory — store safely, never commit)

### 4. Apply

Deploy using the service account key from setup:

```shell
docker run --rm \
  -e KEY_CONTENT="$(base64 < ./keys/.{id}-{account}-key.json)" \
  -e CONFIG_CONTENT="$(base64 < config/eks-example.yaml)" \
  ghcr.io/mchmarny/cluster/eks:latest apply
```

Deployment time: approximately 15-20 minutes for full cluster creation.

### 5. Output (optional)

Retrieve deployment outputs (endpoint, access command, etc.) and save to the state volume:

```shell
docker run --rm \
  -v $PWD/state:/state \
  -e KEY_CONTENT="$(base64 < ./keys/.{id}-{account}-key.json)" \
  -e CONFIG_CONTENT="$(base64 < config/eks-example.yaml)" \
  ghcr.io/mchmarny/cluster/eks:latest output
```

The output JSON is saved to `/state/{id}-{account}-output.json`.

### 6. Destroy

Set `deployment.destroy: true` in the config and re-run apply (step 4).

### Local Deployment (without container)

```shell
provider/eks/tools/actuate -c config/eks-example.yaml apply    # plan + apply
provider/eks/tools/actuate -c config/eks-example.yaml plan     # plan only
provider/eks/tools/validate -c config/eks-example.yaml         # post-deploy checks
```

---

## Configuration Reference

### Config Tiers

#### Minimal (no custom networking)

Pods use the primary VPC CIDR. No secondary CIDR, pod subnets, or ENIConfig resources are created.

```yaml
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster

deployment:
  id: mini
  provider: eks
  tenancy: "123456789012"
  location: us-east-1
  state: tenancy

cluster:
  version: "1.35"
  addOns:
    coreDns: ""
    kubeProxy: ""

compute:
  nodeGroups:
    system:
      instanceType: m7i.xlarge
      capacity:
        desired: 2
    workers:
      - name: cpu-worker-1
        instanceType: m7i.xlarge
        capacity:
          desired: 1
        labels:
          nodeGroup: cpu-worker
```

#### With VPC CNI custom networking (auto-computed subnets)

Adding `vpcCni` to `cluster.addOns` enables custom networking. A secondary CIDR, pod subnets, pod SG, and ENIConfig are automatically created. Subnet CIDRs are auto-computed from the VPC CIDR when `network.subnets` is omitted.

```yaml
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster

deployment:
  id: demo
  provider: eks
  tenancy: "123456789012"
  location: us-east-1

cluster:
  version: "1.35"
  addOns:
    coreDns: ""
    vpcCni: ""
    kubeProxy: ""

compute:
  nodeGroups:
    system:
      instanceType: m6i.xlarge
      capacity:
        desired: 3
```

#### With VPC CNI and explicit network config

Full control over CIDRs and subnets.

```yaml
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster

deployment:
  id: d1
  provider: eks
  tenancy: "123456789012"
  location: us-east-1

cluster:
  version: "1.35"
  addOns:
    coreDns: ""
    vpcCni: ""
    kubeProxy: ""

network:
  cidrs:
    host: 10.0.0.0/16
    pod: 100.65.0.0/16
  subnets:
    public:
      - cidr: 10.0.1.0/27
        zone: us-east-1a
      - cidr: 10.0.2.0/27
        zone: us-east-1b
    system:
      - cidr: 10.0.4.0/22
        zone: us-east-1a
      - cidr: 10.0.8.0/22
        zone: us-east-1b
    worker:
      - cidr: 10.0.128.0/17
        zone: us-east-1a
    pod:
      - cidr: 100.65.0.0/18
        zone: us-east-1a
      - cidr: 100.65.64.0/18
        zone: us-east-1b

compute:
  nodeGroups:
    system:
      instanceType: m6i.xlarge
      capacity:
        desired: 3
```

Notes:
- Your current IP is automatically added to the API server allowed CIDRs during deployment
- `sshPublicKey` is optional — if omitted, no SSH key pair is created
- `imageId` is optional — if omitted, the latest Ubuntu EKS Worker AMI is auto-selected based on `architecture` (defaults to x86_64)
- System nodes use the AL2023 EKS AMI (managed node group); workers use Ubuntu EKS AMI
- When using automatic AMI selection, `cluster.version` must be specified

### Adding Allowed CIDRs

To access the cluster API from a new location, add your egress CIDR to the config and re-apply:

```bash
# Get your current egress CIDR
tools/cidr
# 128.77.49.34/32
```

Add it to the config under `cluster.eks.controlPlane.allowedCidrs`:

```yaml
controlPlane:
  allowedCidrs:
    - 128.77.49.34/32
```

Then re-apply with the same container image. This persists the CIDR in config for future applies.

### Complete Config Reference

Every field Terraform reads, annotated with defaults. Omit any field to use its default.

```yaml
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster

deployment:
  id: ""                         # Required. Prefix for all AWS resources
  provider: eks                  # Required. Must be "eks"
  tenancy: ""                    # Required. AWS account ID
  location: ""                   # Required. AWS region
  state: tenancy                 # "tenancy" (S3) or "local" (tfstate file)
  destroy: false                 # Set true to destroy all resources
  tags: {}                       # Key-value tags applied to all resources

cluster:
  name: ""                       # Defaults to deployment.id
  version: ""                    # K8s version (required for AMI auto-select)
  addOns:                        # Omit key to disable; "" = latest version
    coreDns: ""
    vpcCni: ""                   # Enables custom networking (secondary CIDR, pod subnets, ENIConfig)
    kubeProxy: ""
    cloudwatchObservability: ""
    metricsServer: ""
    ebsCsi: ""
  controlPlane:
    cidr: 172.20.0.0/16          # Service CIDR
    allowedCidrs: []             # API server access CIDRs (your IP auto-added)
  adminRoles: []                 # IAM role names or ARNs for cluster admin access

network:
  cidrs:
    host: 10.0.0.0/16           # VPC CIDR
    pod: 100.65.0.0/16          # Secondary CIDR (only when vpcCni enabled)
  subnets:                       # Auto-computed from VPC CIDR if omitted
    public: [{cidr, zone}]
    system: [{cidr, zone}]
    worker: [{cidr, zone, disableEndpoints}]
    pod: [{cidr, zone, disableEndpoints}]   # Only when vpcCni enabled
  endpoints:                     # Default: [s3, ssm, ec2messages, ssmmessages, logs]
    - s3
    - ssm
    - ec2messages
    - ssmmessages
    - logs
  securityGroups:
    additionalRules:             # Custom security group rules
      - target: system|worker|pod
        direction: ingress|egress
        description: ""
        fromPort: 0
        toPort: 0
        protocol: tcp|udp|-1
        cidrBlocks: []

iam:
  systemNodePolicies: []         # Additional IAM policy ARNs for system nodes
  workerNodePolicies: []         # Additional IAM policy ARNs for worker nodes

security:
  kms:
    deletionWindowInDays: 30     # 7-30

observability:
  logRetentionInDays: 7          # EKS control plane log retention
  vpcFlowLogs:
    retentionInDays: 7
  metrics:
    granularity: "1Minute"       # "1Minute" or "5Minute"

networking:
  vpcCni:
    minimumIpTarget: 30          # Only when vpcCni add-on enabled
    warmIpTarget: 20

compute:
  sshPublicKey: ""               # Omit for no SSH access

  nodeGroups:
    system:                      # EKS managed node group (AL2023 AMI)
      instanceType: ""           # Required
      capacity:
        desired: 0               # Required
        min: 0                   # Defaults to desired
        max: 0                   # Defaults to desired
      blockDevice:
        size: 50                 # GB (only size is configurable for managed node groups)
      labels: {}

    workers:                     # Self-managed node groups (Ubuntu EKS AMI)
      - name: ""                 # Required, unique per worker
        instanceType: ""         # Required
        architecture: x86_64     # x86_64 or arm64
        accelerator: ""          # Auto-derived from instance type (p5=h100, p6e/p6i=gb200)
        gpuType: ""              # GPU identifier label
        imageId: ""              # Omit for auto-select based on architecture
        capacity:
          desired: 0
          min: 0                 # Defaults to desired
          max: 0                 # Defaults to desired
          reservation:
            marketType: ""       # capacity-block or spot
            preference: ""       # capacity-reservations-only
            target: ""           # cr-xxx (ODCR), full ARN, or resource group name
        blockDevice:
          mount: /dev/sda1
          type: gp3
          size: 50               # GB
        labels: {}

  autoscaling:
    healthCheck:
      gracePeriod: 300           # Seconds before health checks start
    capacityTimeout: "10m"       # Max wait for ASG capacity
    deleteTimeout: "30m"         # Max wait for ASG deletion
    instanceRefresh:
      minHealthyPercentage: 90   # Min % healthy during rolling updates
      instanceWarmup: 300        # Seconds for new instances to warm up
      checkpointPercentages: [50, 100]
```

### Defaults

| Setting | Default |
|---------|---------|
| VPC CIDR | `10.0.0.0/16` |
| Pod CIDR (when vpcCni enabled) | `100.65.0.0/16` |
| Service CIDR | `172.20.0.0/16` |
| VPC endpoints | s3, ssm, ec2messages, ssmmessages, logs |
| EKS log retention | 7 days |
| VPC Flow Log retention | 7 days |
| Metrics granularity | 1Minute |
| KMS deletion window | 30 days |
| System node image | AL2023 EKS AMI |
| Worker node image | Ubuntu EKS AMI (Canonical) |
| Worker architecture | x86_64 |
| Block device type | gp3 |
| Block device size | 50 GB |
| Block device mount | /dev/sda1 |
| ASG health check grace | 300 seconds |
| ASG capacity timeout | 10m |
| ASG delete timeout | 30m |
| Instance refresh min healthy | 90% |
| Instance warmup | 300 seconds |
| VPC CNI minimum IP target | 30 |
| VPC CNI warm IP target | 20 |

---

## What Gets Created

| Category | Resources |
|----------|-----------|
| Network | VPC, public/system/worker subnets (+ pod subnets when vpcCni enabled), internet gateway, NAT gateways, route tables |
| VPC Endpoints | Private endpoints for S3, SSM, EC2Messages, SSMMessages, CloudWatch Logs |
| Security | Security groups (cluster, system, worker, EFA; + pod SG when vpcCni enabled), KMS key for secrets and logs |
| EKS | Cluster, OIDC provider, access entries for admin roles |
| Add-ons | CoreDNS, kube-proxy, VPC CNI, CloudWatch Observability, Metrics Server, EBS CSI (each opt-in) |
| Compute | System managed node group (AL2023), worker launch templates + ASGs (Ubuntu), SSH key pair (optional) |
| IAM | Cluster role, system node role, worker node role, IRSA roles for CloudWatch and EBS CSI, VPC Flow Logs role |
| Observability | CloudWatch log group for control plane logs, VPC Flow Logs log group, ASG CloudWatch metrics |
| VPC CNI (optional) | Secondary VPC CIDR association, ENIConfig per AZ, pod security group |

---

## Troubleshooting

### Nodes Not Ready

Causes: VPC CNI not running, ENIConfig zone mismatch (when `vpcCni` enabled), security group blocking traffic.

```bash
kubectl get nodes -o wide
kubectl get ds aws-node -n kube-system
kubectl logs -n kube-system -l k8s-app=aws-node
```

### Pods Pending Due to Taints

All node groups have taints. Add tolerations to your pod spec:

```yaml
tolerations:
- key: "dedicated"
  operator: "Equal"
  value: "worker-workload"    # or "system-workload" for system nodes
  effect: "NoSchedule"
- key: "dedicated"
  operator: "Equal"
  value: "worker-workload"
  effect: "NoExecute"
```

### EBS Volumes Not Attaching

EBS CSI add-on not enabled or IAM role misconfigured.

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver
```

### Cluster Autoscaler Not Scaling

Verify ASG tags exist:

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names {id}-{worker-name} \
  --query 'AutoScalingGroups[].Tags[?starts_with(Key, `k8s.io/cluster-autoscaler`)]'
```

### Terraform State Lock

Previous deployment interrupted. Check for stale locks:

```bash
aws dynamodb get-item \
  --table-name terraform-lock \
  --key '{"LockID":{"S":"cluster-state-{account}/deployments/{region}/{id}/terraform.tfstate"}}'
```

### Metrics Server Not Working

```bash
kubectl get deployment metrics-server -n kube-system
kubectl logs -n kube-system deployment/metrics-server
```
