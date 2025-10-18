# EKS Cluster Using custom cluster name

## Setup 

Define deployment variables:

```shell
export STACK="demo"
export REGION="us-east-1"
export IMAGE="Ubuntu 22.04"
```

Derived values:

```shell
export EGRESS_IP=$(curl -s https://ipinfo.io/ip)
export IMAGE_AMD=$(aws ec2 describe-images --filters "Name=name,Values=${IMAGE}/*/x86_64" \
  --region $REGION --output text --query "Images | sort_by(@, &CreationDate)[-1].ImageId")
export IMAGE_ARM=$(aws ec2 describe-images --filters "Name=name,Values=${IMAGE}/*/aarch64" \
  --region $REGION --output text --query "Images | sort_by(@, &CreationDate)[-1].ImageId")
```

Print derived values:

```shell
echo "Stack: $STACK"
echo "Region: $REGION"
echo "AMD AMI: $IMAGE_AMD"
echo "ARM AMI: $IMAGE_ARM"
echo "Egress IP: $EGRESS_IP"
```

> Validate the output to make sure that all values are populated!

## Create 

Using defaults (cluster name = stack name)

```shell
aws cloudformation create-stack \
  --region $REGION \
  --stack-name "$STACK" \
  --template-body file://cluster.yaml \
  --capabilities CAPABILITY_IAM \
  --parameters \
    ParameterKey=ClusterName,ParameterValue="$STACK" \
    ParameterKey=ControlPlaneAllowedCidrs,ParameterValue="${EGRESS_IP}/32" \
    ParameterKey=SystemNodeDesiredSize,ParameterValue="3" \
    ParameterKey=SystemNodeInstanceTypes,ParameterValue="m7a.xlarge" \
    ParameterKey=SystemNodeAmiId,ParameterValue="$IMAGE_AMD" \
    ParameterKey=CpuWorkerNodeDesiredSize,ParameterValue="2" \
    ParameterKey=CpuWorkerNodeInstanceTypes,ParameterValue="m7a.xlarge" \
    ParameterKey=CpuWorkerNodeAmiId,ParameterValue="$IMAGE_AMD" \
    ParameterKey=GpuWorkerNodeDesiredSize,ParameterValue="2" \
    ParameterKey=GpuWorkerNodeAmiId,ParameterValue="$IMAGE_ARM" \
    ParameterKey=GpuWorkerNodeInstanceTypes,ParameterValue="t4g.xlarge" \
  --tags Key=env,Value="$STACK" Key=owner,Value=$USER
```

## Update

Update the stack with specific params:

```shell
aws cloudformation update-stack \
  --region $REGION \
  --stack-name "$STACK" \
  --template-body file://cluster.yaml \
  --capabilities CAPABILITY_IAM \
  --parameters \
    ParameterKey=ClusterName,ParameterValue="$STACK" \
    ParameterKey=ControlPlaneAllowedCidrs,ParameterValue="${EGRESS_IP}/32" \
    ParameterKey=CpuWorkerNodeDesiredSize,ParameterValue="3"
```

## Config

List of all the parameters that can be used to override defaults:

```shell
    ParameterKey=ClusterName,ParameterValue="my-k8s-cluster" \
    ParameterKey=EksVersion,ParameterValue="1.33" \
    ParameterKey=VpcCniVersion,ParameterValue="v1.20.2-eksbuild.1" \
    ParameterKey=CoreDnsVersion,ParameterValue="v1.12.2-eksbuild.4" \
    ParameterKey=SystemNodeInstanceTypes,ParameterValue="m7a.large" \
    ParameterKey=CpuWorkerNodeInstanceTypes,ParameterValue="m7a.small" \
    ParameterKey=GpuWorkerNodeInstanceTypes,ParameterValue="m7g.small" \
    ParameterKey=SystemNodeDesiredSize,ParameterValue="3" \
    ParameterKey=CpuWorkerNodeDesiredSize,ParameterValue="2" \
    ParameterKey=GpuWorkerNodeDesiredSize,ParameterValue="2" \
    ParameterKey=SystemNodeDiskSize,ParameterValue="500" \
    ParameterKey=CpuWorkerNodeDiskSize,ParameterValue="500" \
    ParameterKey=GpuWorkerNodeDiskSize,ParameterValue="500" \
    ParameterKey=SystemNodeAmiId,ParameterValue="ami-0c02fb55956c7d316" \
    ParameterKey=CpuWorkerNodeAmiId,ParameterValue="ami-0c02fb55956c7d316" \
    ParameterKey=GpuWorkerNodeAmiId,ParameterValue="ami-0735c191cf914754d" \
    ParameterKey=SystemNodeBootstrapScript,ParameterValue="$(cat scripts/bootstrap-common; echo; cat scripts/bootstrap-system)" \
    ParameterKey=CpuWorkerNodeBootstrapScript,ParameterValue="$(cat scripts/bootstrap-common; echo; cat scripts/bootstrap-cpu)" \
    ParameterKey=GpuWorkerNodeBootstrapScript,ParameterValue="$(cat scripts/bootstrap-common; echo; cat scripts/bootstrap-gpu)" \
    ParameterKey=ControlPlaneAllowedCidrs,ParameterValue="1.2.3.4/32,5.6.7.8/32" \
    ParameterKey=VpcCidr,ParameterValue=10.0.0.0/16 \
    ParameterKey=SecondaryVpcCidr,ParameterValue=100.65.0.0/16 \
    ParameterKey=PublicSubnet1Cidr,ParameterValue=10.0.1.0/24 \
    ParameterKey=PublicSubnet2Cidr,ParameterValue=10.0.2.0/24 \
    ParameterKey=SystemSubnet1Cidr,ParameterValue=10.0.4.0/22 \
    ParameterKey=SystemSubnet2Cidr,ParameterValue=10.0.8.0/22 \
    ParameterKey=WorkerSubnet1Cidr,ParameterValue=10.0.128.0/18 \
    ParameterKey=WorkerSubnet2Cidr,ParameterValue=10.0.192.0/18 \
    ParameterKey=PodSubnet1Cidr,ParameterValue=100.65.0.0/18 \
    ParameterKey=PodSubnet2Cidr,ParameterValue=100.65.64.0/18 \
```

## Wait 

You can wait for the update to complete: 

```shell
aws cloudformation wait stack-update-complete --stack-name "$STACK" --region "$REGION"`
```

## Verify

Wait for stack output to be: `CREATE_COMPLETE`

```shell
aws cloudformation describe-stacks --stack-name "$STACK" --region "$REGION" --query 'Stacks[0].StackStatus'
```

> If status is anything else, check [Debug Section](#debug). 

### Debug 

Output stack creation failures:

```shell
aws cloudformation describe-stack-events --stack-name "$STACK" --region $REGION \
  --query 'StackEvents[?ResourceStatus==`CREATE_FAILED`].[Timestamp,LogicalResourceId,ResourceType,ResourceStatusReason]' \
  --output text
```

### Cleanup 

```shell
aws cloudformation delete-stack --stack-name "$STACK" --region $REGION
aws cloudformation wait stack-delete-complete --stack-name "$STACK" --region $REGION
```