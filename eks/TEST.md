# EKS Cluster Validation Test Plan

This test plan validates the EKS cluster deployment with progressively more complex configurations.

---

## Step 1: Setup

### Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.13.0
- yq >= 4.0
- kubectl >= 1.28
- jq >= 1.6

### Verify AWS Authentication

```bash
aws sts get-caller-identity
```

### Initialize Backend

Run setup with any config file to initialize the S3 backend and IAM resources:

```bash
tools/setup configs/minimal.yaml
```

> **Note:** If you see an error about stale Terraform cache, run:
> ```bash
> rm -rf terraform/.terraform terraform/.terraform.lock.hcl
> ```

### Export Credentials

After setup, export the service account credentials:

```bash
export AWS_ACCESS_KEY_ID=$(jq -r .AccessKey.AccessKeyId ./<ACCOUNT_ID>-key.json)
export AWS_SECRET_ACCESS_KEY=$(jq -r .AccessKey.SecretAccessKey ./<ACCOUNT_ID>-key.json)
```

### Discover Available Versions

Use the discovery tool to find supported Kubernetes and add-on versions:

```bash
./tools/disco

# Or specify a region
./tools/disco -r us-west-2
```

**Example output:**
```
Supported Kubernetes Versions:
------------------------------
  - 1.35
  - 1.34
  - 1.33
  ...

Available Add-on Versions:
--------------------------
  coredns:
    - v1.13.1-eksbuild.1
    - v1.12.4-eksbuild.6
  ...
```

---

## Step 2: System-Only Cluster

**Objective:** Validate basic cluster creation with only system nodes.

### 2.1 Create Config

Create `configs/test-system-only.yaml`:

```yaml
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster
deployment:
  id: test-system-only
  tenancy: "YOUR_AWS_ACCOUNT_ID"
  location: us-west-2
cluster:
  name: test-system-only
  version: "1.33"
compute:
  nodeGroups:
    system:
      instanceType: t3.xlarge
      capacity:
        desired: 3
```

> **Note:** This is the most minimal configuration. Network subnets, tags, and AMI are all auto-computed with sensible defaults.

### 2.2 Actuate

```bash
tools/actuate configs/test-system-only.yaml
```

### 2.3 Validate

```bash
./tools/validate configs/test-system-only.yaml
```

**Manual Verification:**

```bash
# Configure kubectl
aws eks update-kubeconfig --name test-system-only --region us-west-2

# Check nodes (expect 3 system nodes)
kubectl get nodes

# Verify taints
kubectl describe nodes | grep -A 3 Taints
# Expected: dedicated=system-workload:NoSchedule, dedicated=system-workload:NoExecute

# Check system pods
kubectl get pods -A
# Expected: VPC CNI, kube-proxy running
```

### 2.4 Delete

```bash
yq -i '.deployment.destroy = true' configs/test-system-only.yaml
tools/actuate configs/test-system-only.yaml
```

## Step 3: System + CPU Workers

**Objective:** Validate cluster with system nodes and multiple CPU worker pools.

### 3.1 Create Config

Create `configs/test-cpu-workers.yaml`:

```yaml
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster
deployment:
  id: test-cpu-workers
  tenancy: "YOUR_AWS_ACCOUNT_ID"
  location: us-west-2
cluster:
  name: test-cpu-workers
  version: "1.34"
compute:
  nodeGroups:
    system:
      instanceType: t3.xlarge
      capacity:
        desired: 3

    workers:
      - name: cpu-worker-1
        instanceType: t3.xlarge
        capacity:
          desired: 1
        labels:
          nodeGroup: cpu-worker1

      - name: cpu-worker-2
        instanceType: t3.xlarge
        capacity:
          desired: 1
        labels:
          nodeGroup: cpu-worker2
```

> **Note:** Each worker requires a unique `name` field. Labels are optional but useful for node selection.

### 3.2 Actuate

```bash
tools/actuate configs/test-cpu-workers.yaml
```

### 3.3 Validate

```bash
./tools/validate configs/test-cpu-workers.yaml
```

**Manual Verification:**

```bash
# Configure kubectl
aws eks update-kubeconfig --name test-cpu-workers --region us-west-2

# Check all nodes (expect 3 system + 2 workers = 5 nodes)
kubectl get nodes
kubectl get nodes --show-labels | grep nodeGroup

# Verify taints
kubectl describe nodes | grep -A 3 Taints
# System nodes: dedicated=system-workload:NoSchedule/NoExecute
# Worker nodes: dedicated=worker-workload:NoSchedule/NoExecute

# Verify labels
kubectl get nodes -l nodeGroup=cpu-worker1
kubectl get nodes -l nodeGroup=cpu-worker2

# Test workload scheduling on workers
kubectl run test-worker1 --image=nginx --restart=Never \
  --overrides='{"spec":{"tolerations":[{"key":"dedicated","operator":"Equal","value":"worker-workload","effect":"NoSchedule"}],"nodeSelector":{"nodeGroup":"cpu-worker1"}}}'

kubectl run test-worker2 --image=nginx --restart=Never \
  --overrides='{"spec":{"tolerations":[{"key":"dedicated","operator":"Equal","value":"worker-workload","effect":"NoSchedule"}],"nodeSelector":{"nodeGroup":"cpu-worker2"}}}'

# Verify pods scheduled correctly
kubectl get pods -o wide
kubectl delete pod test-worker1 test-worker2
```

### 3.4 Delete

```bash
yq -i '.deployment.destroy = true' configs/test-cpu-workers.yaml
tools/actuate configs/test-cpu-workers.yaml
```

## Step 4: System + CPU + GPU Workers

**Objective:** Validate cluster with GPU node pool and EFA networking.

> **Warning:** GPU instances have limited availability and higher cost. Ensure account limits and budget before running.

### 4.1 Create Config

Create `configs/test-cpu-gpu-workers.yaml`:

```yaml
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster
deployment:
  id: test-cpu-gpu-workers
  tenancy: "YOUR_AWS_ACCOUNT_ID"
  location: us-east-1
cluster:
  name: test-cpu-gpu-workers
  version: "1.34"
compute:
  sshPublicKey: "ssh-ed25519 YOUR_SSH_PUBLIC_KEY"  # Recommended for GPU debugging

  nodeGroups:
    system:
      instanceType: t3.xlarge
      capacity:
        desired: 3

    workers:
      - name: cpu-worker
        instanceType: t3.xlarge
        capacity:
          desired: 1
        labels:
          nodeGroup: cpu-worker

      - name: gpu-worker
        instanceType: p5.48xlarge
        accelerator: h100
        imageId: ami-0a7bcc9b03849f089
        capacity:
          desired: 1
          reservation:
            preference: capacity-reservations-only
            target: cr-0cbe491320188dfa6  # Your ODCR ID
        labels:
          gpu: "true"
```

#### Capacity Reservation Types

| Type | `marketType` | `target` format | Example |
|------|--------------|-----------------|---------|
| **On-Demand Capacity Reservation (ODCR)** | Not needed | `cr-xxx` | `cr-0cbe491320188dfa6` |
| **Capacity Block for ML** | `capacity-block` | ARN | `arn:aws:ec2:region:account:capacity-block/...` |
| **Spot Instances** | `spot` | Not needed | N/A |
| **Resource Group (shared)** | Optional | ARN or name | `my-resource-group` |

> **Note:** For On-Demand Capacity Reservations (most common), only `preference` and `target` are needed. Do NOT set `marketType` for ODCRs.

### 4.2 Actuate

```bash
tools/actuate configs/test-cpu-gpu-workers.yaml
```

### 4.3 Validate

```bash
./tools/validate configs/test-cpu-gpu-workers.yaml
```

**Manual Verification:**

```bash
# Configure kubectl
aws eks update-kubeconfig --name test-cpu-gpu-workers --region us-east-1

# Check all nodes (expect 3 system + 1 cpu + 1 gpu = 5 nodes)
kubectl get nodes
kubectl get nodes -l gpu=true

# Verify GPU node has correct labels
kubectl describe node <gpu-node-name> | grep -A 5 Labels
# Expected: gpu=true

# Verify EFA security group
aws ec2 describe-security-groups --filters "Name=group-name,Values=*efa*" \
  --query 'SecurityGroups[].GroupId'

# Test GPU workload (optional - requires NVIDIA device plugin)
kubectl run gpu-test --image=nvidia/cuda:12.0-base --restart=Never \
  --overrides='{"spec":{"tolerations":[{"key":"dedicated","operator":"Equal","value":"worker-workload","effect":"NoSchedule"}],"nodeSelector":{"gpu":"true"},"containers":[{"name":"gpu-test","image":"nvidia/cuda:12.0-base","command":["nvidia-smi"]}]}}'

kubectl logs gpu-test
kubectl delete pod gpu-test
```

### 4.4 Delete

```bash
yq -i '.deployment.destroy = true' configs/test-cpu-gpu-workers.yaml
tools/actuate configs/test-cpu-gpu-workers.yaml
```

## Troubleshooting

### Nodes Not Joining

```bash
# Check ASG status
aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names <name>

# Check instance status
aws ec2 describe-instances --filters "Name=tag:Name,Values=*system*" \
  --query 'Reservations[].Instances[].{ID:InstanceId,State:State.Name}'

# Check node bootstrap logs (via SSM)
aws ssm start-session --target <instance-id>
sudo journalctl -u kubelet -f
```

### API Server Unreachable

```bash
# Verify your IP was added
aws eks describe-cluster --name <cluster-name> \
  --query 'cluster.resourcesVpcConfig.publicAccessCidrs'

# Check current egress IP
curl -s https://checkip.amazonaws.com
```

### Destroy Stuck

```bash
# Check for dependencies
aws eks list-nodegroups --cluster-name <cluster-name>
aws eks list-fargate-profiles --cluster-name <cluster-name>

# Force delete stuck resources (use with caution)
aws eks delete-cluster --name <cluster-name> --force
```

### Stale Terraform State

If switching AWS accounts or seeing backend errors:

```bash
rm -rf terraform/.terraform terraform/.terraform.lock.hcl
tools/setup configs/<config>.yaml
```

---

## Notes

- **Automated Validation:** Use `tools/validate` for consistent, repeatable cluster verification.
- **Cost Warning:** GPU instances incur significant costs. Destroy promptly after testing.
- **IP Auto-Addition:** Terraform automatically adds your current IP to the API server allowed CIDRs.
- **Automatic AMI Selection:** When `imageId` is omitted, Terraform selects the latest Ubuntu EKS Worker AMI (x86_64). Requires `cluster.version` to be set.
- **ARM64 Nodes:** Automatic AMI selection only supports x86_64. ARM64 nodes require explicit `imageId`.
- **SSH Access:** `sshPublicKey` is optional. If omitted, nodes have no SSH access (use SSM Session Manager instead).
- **Capacity Reservations:** For GPU workloads, configure capacity reservations using the `target` field.
- **Minimal Config:** Network subnets and tags are optional. Terraform auto-computes default CIDRs from the VPC CIDR (10.0.0.0/16).
