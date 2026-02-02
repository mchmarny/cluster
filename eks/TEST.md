# EKS Cluster Validation Test Plan

This test plan validates the EKS cluster deployment with progressively more complex configurations.

## Prerequisites

- AWS CLI configured with appropriate credentials
- Terraform >= 1.13.0
- yq >= 4.0
- kubectl >= 1.28
- jq >= 1.6

> Make sure to run `tools/setup configs/<config>.yaml` before starting tests!

## Automated Validation

Use the `tools/validate` script to automatically verify cluster configuration:

```bash
./tools/validate configs/test-system-only.yaml
```

The script performs 30 automated checks and exits with code 0 on success, non-zero on failure.

### Checks Performed

| Category | Checks |
|----------|--------|
| **EKS Cluster** | Status (ACTIVE), version, service CIDR, endpoint |
| **VPC** | VPC ID, subnet count, public/system/worker/pod subnets |
| **VPC Endpoints** | s3, ssm, ssmmessages, ec2messages, logs availability |
| **Nodes** | Count matches config, all Ready, taints applied |
| **ASG** | Exists, desired capacity, multi-AZ spread |
| **ENI Configs** | Custom networking configured per AZ |
| **Core Components** | VPC CNI (aws-node), kube-proxy running |
| **Security Groups** | System and worker security groups exist |
| **IAM Roles** | EKS cluster, system nodes, worker nodes roles |

### Example Output

```
[MSG] Validating cluster: test-system-only in us-west-2
[MSG] Checking EKS cluster...
[MSG] PASS: Cluster status is ACTIVE
[MSG] PASS: Cluster version starts with 1.33
...
==============================================
Validation Summary
==============================================
[MSG] Passed: 30
[MSG] All checks passed!
```

## Test Configurations

Create the following test configuration files before running tests.

### Test 1: System-Only Cluster (Minimal)

**File:** `configs/test-system-only.yaml`

**Status:** ✅ Verified

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

### Test 2: System + CPU Workers

**File:** `configs/test-cpu-workers.yaml`

**Status:** ✅ Verified

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
  version: "1.34"

compute:
  sshPublicKey: "ssh-ed25519 YOUR_SSH_PUBLIC_KEY"  # Recommended for GPU debugging

  nodeGroups:
    system:
      instanceType: t3.xlarge
      # imageId: auto-selected Ubuntu EKS AMI (amd64)
      capacity:
        desired: 3

    workers:
      - name: cpu-worker
        instanceType: t3.xlarge
        capacity:
          desired: 2

      - name: gpu-worker
        instanceType: p5.48xlarge
        accelerator: v100
        imageId: ami-0a7bcc9b03849f089
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

**Automated Validation (Recommended):**

```bash
./tools/validate configs/test-system-only.yaml
```

**Manual Verification:**

```bash
# Configure kubectl
aws eks update-kubeconfig --name test-system-only --region us-west-2

# Check nodes (expect 3 system nodes)
kubectl get nodes
kubectl get nodes -o wide

# Verify taints
kubectl describe nodes | grep -A 3 Taints
# Expected: dedicated=system-workload:NoSchedule, dedicated=system-workload:NoExecute

# Check system pods
kubectl get pods -A
# Expected: VPC CNI, kube-proxy running

# Verify VPC endpoints
aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=<vpc-id>" \
  --query 'VpcEndpoints[*].{Service:ServiceName,State:State}' --output table
```

**Pass Criteria:**
- [ ] `tools/validate` exits with code 0
- [ ] 3 nodes in Ready state
- [ ] System taints applied correctly
- [ ] VPC CNI daemonset running on all nodes
- [ ] kube-proxy daemonset running on all nodes
- [ ] 5 VPC endpoints available (s3, ssm, ssmmessages, ec2messages, logs)

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

**Automated Validation (Recommended):**

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

# Verify worker taints
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

**Pass Criteria:**
- [ ] `tools/validate` exits with code 0
- [ ] 5 nodes total in Ready state
- [ ] 3 system nodes with system taints
- [ ] 1 worker with nodeGroup=cpu-worker1 label and worker taints
- [ ] 1 worker with nodeGroup=cpu-worker2 label and worker taints
- [ ] Test pods schedule to correct worker nodes

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

**Automated Validation (Recommended):**

```bash
./tools/validate configs/test-gpu-workers.yaml
```

**Manual Verification:**

```bash
# Configure kubectl
aws eks update-kubeconfig --name test3 --region us-east-1

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
- [ ] `tools/validate` exits with code 0
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
| CPU workers | N/A | [ ] (2) | [ ] (2) |
| GPU workers | N/A | N/A | [ ] (1) |
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

- **Automated Validation:** Use `tools/validate` for consistent, repeatable cluster verification. It performs 30 checks and exits with code 0 on success.
- **Cost Warning:** GPU instances incur significant costs. Destroy promptly after testing.
- **IP Auto-Addition:** Terraform automatically adds your current IP to the API server allowed CIDRs.
- **Automatic AMI Selection:** When `imageId` is omitted, Terraform selects the latest Ubuntu EKS Worker AMI (x86_64) from Canonical. Requires `cluster.version` to be set.
- **ARM64 Nodes:** Automatic AMI selection only supports x86_64. ARM64 nodes require explicit `imageId`.
- **SSH Access:** `sshPublicKey` is optional. If omitted, nodes have no SSH access (use SSM Session Manager instead).
- **Capacity Reservations:** For production GPU workloads, configure capacity reservations in the config.
- **Minimal Config:** Network subnets and tags are optional. Terraform auto-computes default CIDRs from the VPC CIDR (10.0.0.0/16).
