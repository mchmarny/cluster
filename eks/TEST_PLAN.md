# EKS Cluster Validation Test Plan

This test plan validates the EKS cluster deployment with progressively more complex configurations.

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.13.0
- yq >= 4.0
- kubectl >= 1.28
- Run `tools/setup configs/minimal.yaml` before starting tests

## Test Configurations

Create the following test configuration files before running tests.

### Test 1: System-Only Cluster (Minimal)

**File:** `configs/test-system-only.yaml`

```yaml
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster

deployment:
  id: test1
  tenancy: "YOUR_AWS_ACCOUNT_ID"
  location: us-east-1

cluster:
  name: test1
  version: "1.32"  # Required for automatic AMI selection

compute:
  # sshPublicKey: "ssh-ed25519 YOUR_SSH_PUBLIC_KEY"  # Optional

  nodeGroups:
    system:
      instanceType: m6i.xlarge
      # imageId: ami-xxx  # Optional: defaults to Ubuntu EKS AMI (amd64)
      capacity:
        desired: 3
```

> **Note:** This test validates the minimal configuration with automatic Ubuntu EKS AMI selection and no SSH access.

### Test 2: System + CPU Workers

**File:** `configs/test-cpu-workers.yaml`

```yaml
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster

deployment:
  id: test2
  tenancy: "YOUR_AWS_ACCOUNT_ID"
  location: us-east-1

cluster:
  name: test2
  version: "1.32"

compute:
  sshPublicKey: "ssh-ed25519 YOUR_SSH_PUBLIC_KEY"  # Optional but useful for debugging

  nodeGroups:
    system:
      instanceType: m6i.xlarge
      # imageId: auto-selected Ubuntu EKS AMI (amd64)
      capacity:
        desired: 3

    workers:
      - name: cpu-worker-amd
        instanceType: m6i.xlarge
        # imageId: auto-selected Ubuntu EKS AMI (amd64)
        capacity:
          desired: 2
        labels:
          arch: amd64

      - name: cpu-worker-arm
        instanceType: c6gn.xlarge
        imageId: ami-09bf1e83f45a97282  # Required: arm64 AMI (auto-select is x86_64 only)
        capacity:
          desired: 2
        labels:
          arch: arm64
```

> **Note:** ARM64 worker nodes require explicit `imageId` since automatic AMI selection only supports x86_64.

### Test 3: System + CPU + GPU Workers

**File:** `configs/test-gpu-workers.yaml`

```yaml
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster

deployment:
  id: test3
  tenancy: "YOUR_AWS_ACCOUNT_ID"
  location: us-east-1

cluster:
  name: test3
  version: "1.32"

compute:
  sshPublicKey: "ssh-ed25519 YOUR_SSH_PUBLIC_KEY"  # Recommended for GPU debugging

  nodeGroups:
    system:
      instanceType: m6i.xlarge
      # imageId: auto-selected Ubuntu EKS AMI (amd64)
      capacity:
        desired: 3

    workers:
      - name: cpu-worker
        instanceType: m6i.xlarge
        # imageId: auto-selected Ubuntu EKS AMI (amd64)
        capacity:
          desired: 2

      - name: gpu-worker
        instanceType: p3.2xlarge  # Adjust based on availability
        accelerator: v100
        # imageId: auto-selected Ubuntu EKS AMI (amd64)
        capacity:
          desired: 1
        labels:
          gpu: "true"
```

---

## Test Execution

### Test 1: System-Only Cluster

**Objective:** Validate basic cluster creation with only system nodes.

#### 1.1 Deploy

```bash
tools/actuate configs/test-system-only.yaml
```

**Expected duration:** ~15-20 minutes

#### 1.2 Verify

```bash
# Configure kubectl
aws eks update-kubeconfig --name demo --region us-east-1

# Check nodes (expect 3 system nodes)
kubectl get nodes
kubectl get nodes -o wide

# Verify taints
kubectl describe nodes | grep -A 3 Taints
# Expected: dedicated=system-workload:NoSchedule, dedicated=system-workload:NoExecute

# Check system pods
kubectl get pods -A
# Expected: CoreDNS, VPC CNI, kube-proxy running

# Verify metrics
kubectl top nodes
```

**Pass Criteria:**
- [ ] 3 nodes in Ready state
- [ ] System taints applied correctly
- [ ] CoreDNS pods running (2 replicas)
- [ ] VPC CNI daemonset running on all nodes
- [ ] kube-proxy daemonset running on all nodes
- [ ] Metrics server responding

#### 1.3 Destroy

```bash
# Update config to set destroy: true
yq -i '.deployment.destroy = true' configs/test-system-only.yaml

# Destroy cluster
tools/actuate configs/test-system-only.yaml
```

**Expected duration:** ~10-15 minutes

**Pass Criteria:**
- [ ] All EC2 instances terminated
- [ ] EKS cluster deleted
- [ ] VPC and subnets removed
- [ ] No orphaned resources in AWS console

---

### Test 2: System + CPU Workers

**Objective:** Validate cluster with system nodes and multiple CPU worker pools.

#### 2.1 Deploy

```bash
tools/actuate configs/test-cpu-workers.yaml
```

**Expected duration:** ~20-25 minutes

#### 2.2 Verify

```bash
# Configure kubectl
aws eks update-kubeconfig --name demo --region us-east-1

# Check all nodes (expect 3 system + 2 amd + 2 arm = 7 nodes)
kubectl get nodes
kubectl get nodes --show-labels | grep arch

# Verify worker taints
kubectl describe nodes | grep -A 3 Taints
# System nodes: dedicated=system-workload:NoSchedule/NoExecute
# Worker nodes: dedicated=worker-workload:NoSchedule/NoExecute

# Verify labels
kubectl get nodes -l arch=amd64
kubectl get nodes -l arch=arm64

# Test workload scheduling on workers
kubectl run test-amd --image=nginx --restart=Never \
  --overrides='{"spec":{"tolerations":[{"key":"dedicated","operator":"Equal","value":"worker-workload","effect":"NoSchedule"}],"nodeSelector":{"arch":"amd64"}}}'

kubectl run test-arm --image=nginx --restart=Never \
  --overrides='{"spec":{"tolerations":[{"key":"dedicated","operator":"Equal","value":"worker-workload","effect":"NoSchedule"}],"nodeSelector":{"arch":"arm64"}}}'

# Verify pods scheduled correctly
kubectl get pods -o wide
kubectl delete pod test-amd test-arm
```

**Pass Criteria:**
- [ ] 7 nodes total in Ready state
- [ ] 3 system nodes with system taints
- [ ] 2 amd64 workers with worker taints and arch=amd64 label
- [ ] 2 arm64 workers with worker taints and arch=arm64 label
- [ ] Test pods schedule to correct architecture nodes

#### 2.3 Destroy

```bash
yq -i '.deployment.destroy = true' configs/test-cpu-workers.yaml
tools/actuate configs/test-cpu-workers.yaml
```

**Pass Criteria:**
- [ ] All resources cleaned up
- [ ] No orphaned ASGs, launch templates, or security groups

---

### Test 3: System + CPU + GPU Workers

**Objective:** Validate cluster with GPU node pool and EFA networking.

> **Note:** GPU instances have limited availability and higher cost. Ensure account limits and budget before running.

#### 3.1 Deploy

```bash
tools/actuate configs/test-gpu-workers.yaml
```

**Expected duration:** ~25-30 minutes (GPU instances may take longer)

#### 3.2 Verify

```bash
# Configure kubectl
aws eks update-kubeconfig --name demo --region us-east-1

# Check all nodes (expect 3 system + 2 cpu + 1 gpu = 6 nodes)
kubectl get nodes
kubectl get nodes -l gpu=true

# Verify GPU node has correct labels
kubectl describe node <gpu-node-name> | grep -A 5 Labels
# Expected: gpu=true, nodeGroup=gpu-worker

# Verify EFA security group (if applicable)
aws ec2 describe-security-groups --filters "Name=group-name,Values=*efa*" \
  --query 'SecurityGroups[].GroupId'

# Test GPU workload (optional - requires NVIDIA device plugin)
kubectl run gpu-test --image=nvidia/cuda:12.0-base --restart=Never \
  --overrides='{"spec":{"tolerations":[{"key":"dedicated","operator":"Equal","value":"worker-workload","effect":"NoSchedule"}],"nodeSelector":{"gpu":"true"},"containers":[{"name":"gpu-test","image":"nvidia/cuda:12.0-base","command":["nvidia-smi"]}]}}'

kubectl logs gpu-test
kubectl delete pod gpu-test
```

**Pass Criteria:**
- [ ] 6 nodes total in Ready state
- [ ] GPU node has gpu=true label
- [ ] EFA security group created (for EFA-capable instances)
- [ ] GPU workload can detect GPU device (if NVIDIA plugin installed)

#### 3.3 Destroy

```bash
yq -i '.deployment.destroy = true' configs/test-gpu-workers.yaml
tools/actuate configs/test-gpu-workers.yaml
```

**Pass Criteria:**
- [ ] All resources cleaned up including GPU instances
- [ ] No orphaned capacity reservations

---

## Validation Checklist Summary

### Infrastructure

| Component | Test 1 | Test 2 | Test 3 |
|-----------|--------|--------|--------|
| VPC created | [ ] | [ ] | [ ] |
| Subnets (public, system, worker, pod) | [ ] | [ ] | [ ] |
| NAT Gateways | [ ] | [ ] | [ ] |
| Security Groups | [ ] | [ ] | [ ] |
| KMS Key | [ ] | [ ] | [ ] |
| EKS Cluster | [ ] | [ ] | [ ] |
| OIDC Provider | [ ] | [ ] | [ ] |

### Node Groups

| Component | Test 1 | Test 2 | Test 3 |
|-----------|--------|--------|--------|
| System nodes (3) | [ ] | [ ] | [ ] |
| CPU workers (amd64) | N/A | [ ] | [ ] |
| CPU workers (arm64) | N/A | [ ] | N/A |
| GPU workers | N/A | N/A | [ ] |
| Taints applied | [ ] | [ ] | [ ] |
| Labels applied | [ ] | [ ] | [ ] |

### Add-ons

| Component | Test 1 | Test 2 | Test 3 |
|-----------|--------|--------|--------|
| CoreDNS | [ ] | [ ] | [ ] |
| VPC CNI | [ ] | [ ] | [ ] |
| kube-proxy | [ ] | [ ] | [ ] |
| Metrics Server | [ ] | [ ] | [ ] |

### Security

| Component | Test 1 | Test 2 | Test 3 |
|-----------|--------|--------|--------|
| API server accessible | [ ] | [ ] | [ ] |
| User IP auto-added | [ ] | [ ] | [ ] |
| KMS encryption | [ ] | [ ] | [ ] |
| VPC Flow Logs | [ ] | [ ] | [ ] |

### Cleanup

| Component | Test 1 | Test 2 | Test 3 |
|-----------|--------|--------|--------|
| All EC2 terminated | [ ] | [ ] | [ ] |
| EKS deleted | [ ] | [ ] | [ ] |
| VPC removed | [ ] | [ ] | [ ] |
| No orphan resources | [ ] | [ ] | [ ] |

---

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
aws eks describe-cluster --name demo \
  --query 'cluster.resourcesVpcConfig.publicAccessCidrs'

# Check current egress IP
curl -s https://checkip.amazonaws.com
```

### Destroy Stuck

```bash
# Check for dependencies
aws eks list-nodegroups --cluster-name demo
aws eks list-fargate-profiles --cluster-name demo

# Force delete stuck resources (use with caution)
aws eks delete-cluster --name demo --force
```

---

## Notes

- **Cost Warning:** GPU instances incur significant costs. Destroy promptly after testing.
- **IP Auto-Addition:** Terraform automatically adds your current IP to the API server allowed CIDRs.
- **Automatic AMI Selection:** When `imageId` is omitted, Terraform selects the latest Ubuntu EKS Worker AMI (x86_64) from Canonical. Requires `cluster.version` to be set.
- **ARM64 Nodes:** Automatic AMI selection only supports x86_64. ARM64 nodes require explicit `imageId`.
- **SSH Access:** `sshPublicKey` is optional. If omitted, nodes have no SSH access (use SSM Session Manager instead).
- **Capacity Reservations:** For production GPU workloads, configure capacity reservations in the config.
