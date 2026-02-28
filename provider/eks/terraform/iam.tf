# IAM Policy Documents

# #2: Cluster role only needs EKS service trust
data "aws_iam_policy_document" "eks_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# #11: Single node assume role policy (system and worker are identical)
data "aws_iam_policy_document" "node_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# #3: Scope monitoring policy — remove support:AWSSupportAccess
data "aws_iam_policy_document" "monitoring" {
  statement {
    effect = "Allow"
    actions = [
      "tag:GetResources",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
    ]
    resources = ["*"]
  }
}

# #3: Scope flow_log policy to prefix-scoped log groups
data "aws_iam_policy_document" "flow_log" {
  statement {
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:PutLogEvents"
    ]
    resources = [
      "arn:aws:logs:${local.region}:${local.account}:log-group:/aws/vpc/${local.prefix}-*",
      "arn:aws:logs:${local.region}:${local.account}:log-group:/aws/vpc/${local.prefix}-*:*",
      "arn:aws:logs:${local.region}:${local.account}:log-group:/aws/eks/cluster/${local.prefix}-*",
      "arn:aws:logs:${local.region}:${local.account}:log-group:/aws/eks/cluster/${local.prefix}-*:*",
    ]
  }
}

# #3: Scope api policy into specific statements
data "aws_iam_policy_document" "api" {
  # SG mutations scoped to account security groups
  statement {
    sid    = "SecurityGroupMutations"
    effect = "Allow"
    actions = [
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
    ]
    resources = ["arn:aws:ec2:${local.region}:${local.account}:security-group/*"]
  }

  # SG reads require wildcard
  statement {
    sid    = "SecurityGroupReads"
    effect = "Allow"
    actions = [
      "ec2:DescribeSecurityGroupRules",
    ]
    resources = ["*"]
  }

  # Log reads scoped to prefix pattern
  statement {
    sid    = "LogReads"
    effect = "Allow"
    actions = [
      "logs:Describe*",
      "logs:Get*",
      "logs:List*",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:TestMetricFilter",
      "logs:FilterLogEvents",
      "logs:StartLiveTail",
      "logs:StopLiveTail",
    ]
    resources = [
      "arn:aws:logs:${local.region}:${local.account}:log-group:/aws/vpc/${local.prefix}-*",
      "arn:aws:logs:${local.region}:${local.account}:log-group:/aws/vpc/${local.prefix}-*:*",
      "arn:aws:logs:${local.region}:${local.account}:log-group:/aws/eks/cluster/${local.prefix}-*",
      "arn:aws:logs:${local.region}:${local.account}:log-group:/aws/eks/cluster/${local.prefix}-*:*",
    ]
  }

  # EKS cluster operations
  statement {
    sid    = "EKSCluster"
    effect = "Allow"
    actions = [
      "eks:DescribeCluster",
      "eks:UpdateClusterConfig",
    ]
    resources = ["arn:aws:eks:${local.region}:${local.account}:cluster/${local.cluster_name}"]
  }

  # S3 writes scoped to prefix
  statement {
    sid    = "S3Writes"
    effect = "Allow"
    actions = [
      "s3:PutObject",
    ]
    resources = ["arn:aws:s3:::${local.prefix}-*/*"]
  }

  # CloudWatch and ServiceQuotas reads require wildcard
  statement {
    sid    = "ObservabilityReads"
    effect = "Allow"
    actions = [
      "servicequotas:GetServiceQuota",
      "cloudwatch:GetMetricData",
      "cloudwatch:GenerateQuery",
    ]
    resources = ["*"]
  }
}

# IAM Policies
resource "aws_iam_policy" "flow_log" {
  name   = "${local.prefix}-flow-log"
  policy = data.aws_iam_policy_document.flow_log.json

  tags = { Name = "${local.prefix}-flow-log" }
}

resource "aws_iam_policy" "monitoring" {
  name   = "${local.prefix}-monitoring"
  policy = data.aws_iam_policy_document.monitoring.json

  tags = { Name = "${local.prefix}-monitoring" }
}

resource "aws_iam_policy" "api" {
  name   = "${local.prefix}-api"
  policy = data.aws_iam_policy_document.api.json

  tags = { Name = "${local.prefix}-api" }
}

# IAM Roles
resource "aws_iam_role" "eks_cluster" {
  name               = "${local.prefix}-eks"
  assume_role_policy = data.aws_iam_policy_document.eks_assume_role.json

  tags = { Name = "${local.prefix}-eks" }
}

# #11: Both node roles share the same assume role policy
resource "aws_iam_role" "system_nodes" {
  name               = "${local.prefix}-system-nodes"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = { Name = "${local.prefix}-system-nodes" }
}

resource "aws_iam_role" "worker_nodes" {
  name               = "${local.prefix}-worker-nodes"
  assume_role_policy = data.aws_iam_policy_document.node_assume_role.json

  tags = { Name = "${local.prefix}-worker-nodes" }
}


# IAM Role Policy Attachments

# EKS Cluster Role Policies
# #1: Only cluster-level policies on cluster role (removed WorkerNode and CNI)
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_container_registry_readonly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_flow_log" {
  policy_arn = aws_iam_policy.flow_log.arn
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_api" {
  policy_arn = aws_iam_policy.api.arn
  role       = aws_iam_role.eks_cluster.name
}

# System Node Group Role Policies
resource "aws_iam_role_policy_attachment" "system_nodes_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.system_nodes.name
}

resource "aws_iam_role_policy_attachment" "system_nodes_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.system_nodes.name
}

resource "aws_iam_role_policy_attachment" "system_nodes_container_registry_readonly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.system_nodes.name
}

resource "aws_iam_role_policy_attachment" "system_nodes_ssm_managed_instance_core" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.system_nodes.name
}

resource "aws_iam_role_policy_attachment" "system_nodes_service_role_ebs_csi_driver_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.system_nodes.name
}

resource "aws_iam_role_policy_attachment" "system_nodes_monitoring" {
  policy_arn = aws_iam_policy.monitoring.arn
  role       = aws_iam_role.system_nodes.name
}

resource "aws_iam_role_policy_attachment" "system_nodes_api" {
  policy_arn = aws_iam_policy.api.arn
  role       = aws_iam_role.system_nodes.name
}

# #4: Config-driven additional policies for system nodes
resource "aws_iam_role_policy_attachment" "system_nodes_extra" {
  for_each = toset(try(local.config.iam.systemNodePolicies, []))

  policy_arn = each.value
  role       = aws_iam_role.system_nodes.name
}

# Worker Node Group Role Policies
resource "aws_iam_role_policy_attachment" "worker_nodes_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.worker_nodes.name
}

resource "aws_iam_role_policy_attachment" "worker_nodes_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.worker_nodes.name
}

resource "aws_iam_role_policy_attachment" "worker_nodes_container_registry_readonly" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.worker_nodes.name
}

resource "aws_iam_role_policy_attachment" "worker_nodes_ssm_managed_instance_core" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  role       = aws_iam_role.worker_nodes.name
}

resource "aws_iam_role_policy_attachment" "worker_nodes_service_role_ebs_csi_driver_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.worker_nodes.name
}

# #4: Config-driven additional policies for worker nodes
resource "aws_iam_role_policy_attachment" "worker_nodes_extra" {
  for_each = toset(try(local.config.iam.workerNodePolicies, []))

  policy_arn = each.value
  role       = aws_iam_role.worker_nodes.name
}

# Instance Type Profiles for EC2 instances
resource "aws_iam_instance_profile" "system_nodes" {
  name = "${local.prefix}-system-nodes"
  role = aws_iam_role.system_nodes.name

  tags = { Name = "${local.prefix}-system-nodes" }
}

resource "aws_iam_instance_profile" "worker_nodes" {
  name = "${local.prefix}-worker-nodes"
  role = aws_iam_role.worker_nodes.name

  tags = { Name = "${local.prefix}-worker-nodes" }
}

# IAM Role for CloudWatch Observability Addon (IRSA)
data "aws_iam_policy_document" "cloudwatch_observability_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.oidc_provider.arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.oidc_provider.url, "https://", "")}:sub"
      values = [
        "system:serviceaccount:amazon-cloudwatch:cw-observability",
        "system:serviceaccount:amazon-cloudwatch:fluent-bit"
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.oidc_provider.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cloudwatch_observability" {
  name               = "${local.prefix}-cloudwatch-observability"
  assume_role_policy = data.aws_iam_policy_document.cloudwatch_observability_assume_role.json

  tags = { Name = "${local.prefix}-cloudwatch-observability" }
}

resource "aws_iam_role_policy_attachment" "cloudwatch_observability_policy" {
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
  role       = aws_iam_role.cloudwatch_observability.name
}

resource "aws_iam_role_policy_attachment" "cloudwatch_observability_xray_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
  role       = aws_iam_role.cloudwatch_observability.name
}

# IAM Role for EBS CSI Driver Addon (IRSA)
data "aws_iam_policy_document" "ebs_csi_driver_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.oidc_provider.arn]
    }
    actions = ["sts:AssumeRoleWithWebIdentity"]
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.oidc_provider.url, "https://", "")}:sub"
      values = [
        "system:serviceaccount:kube-system:ebs-csi-controller-sa",
        "system:serviceaccount:kube-system:ebs-csi-node-sa"
      ]
    }
    condition {
      test     = "StringEquals"
      variable = "${replace(aws_iam_openid_connect_provider.oidc_provider.url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ebs_csi_driver" {
  name               = "${local.prefix}-ebs-csi-driver"
  assume_role_policy = data.aws_iam_policy_document.ebs_csi_driver_assume_role.json

  tags = { Name = "${local.prefix}-ebs-csi-driver" }
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_driver.name
}
