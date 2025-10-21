# IAM Policy Documents
data "aws_iam_policy_document" "eks_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = [
        "ec2.amazonaws.com",
        "eks.amazonaws.com",
        "vpc-flow-logs.amazonaws.com",
        "servicequotas.amazonaws.com",
        "cloudwatch.amazonaws.com",
        "fsx.amazonaws.com",
      ]
    }
    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "system_nodes_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = [
        "ec2.amazonaws.com",
      ]
    }
    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "worker_nodes_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type = "Service"
      identifiers = [
        "ec2.amazonaws.com",
      ]
    }
    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "monitoring" {
  statement {
    effect = "Allow"
    actions = [
      "tag:GetResources",
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "support:AWSSupportAccess",
    ]
    resources = ["*"]
  }
}

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
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "api" {
  statement {
    effect = "Allow"
    actions = [
      "servicequotas:GetServiceQuota",
      "cloudwatch:GetMetricData",
      "ec2:AuthorizeSecurityGroupIngress",
      "ec2:RevokeSecurityGroupIngress",
      "ec2:DescribeSecurityGroupRules",
      "logs:Describe*",
      "logs:Get*",
      "logs:List*",
      "logs:StartQuery",
      "logs:StopQuery",
      "logs:TestMetricFilter",
      "logs:FilterLogEvents",
      "logs:StartLiveTail",
      "logs:StopLiveTail",
      "cloudwatch:GenerateQuery",
      "s3:PutObject",
      "eks:DescribeCluster",
      "eks:UpdateClusterConfig",
    ]
    resources = ["*"]
  }
}

# IAM Policies
resource "aws_iam_policy" "flow_log" {
  name   = "${local.prefix}-flow-log"
  policy = data.aws_iam_policy_document.flow_log.json

  tags = local.config.deployment.tags
}

resource "aws_iam_policy" "monitoring" {
  name   = "${local.prefix}-monitoring"
  policy = data.aws_iam_policy_document.monitoring.json

  tags = local.config.deployment.tags
}

resource "aws_iam_policy" "api" {
  name   = "${local.prefix}-api"
  policy = data.aws_iam_policy_document.api.json

  tags = local.config.deployment.tags
}

# IAM Roles
resource "aws_iam_role" "eks_cluster" {
  name               = "${local.prefix}-eks"
  assume_role_policy = data.aws_iam_policy_document.eks_assume_role.json

  tags = merge(local.config.deployment.tags, {
    Name = "${local.prefix}-eks"
  })
}

resource "aws_iam_role" "system_nodes" {
  name               = "${local.prefix}-system-nodes"
  assume_role_policy = data.aws_iam_policy_document.system_nodes_assume_role.json

  tags = merge(local.config.deployment.tags, {
    Name = "${local.prefix}-system-nodes"
  })
}

resource "aws_iam_role" "worker_nodes" {
  name               = "${local.prefix}-worker-nodes"
  assume_role_policy = data.aws_iam_policy_document.worker_nodes_assume_role.json

  tags = merge(local.config.deployment.tags, {
    Name = "${local.prefix}-worker-nodes"
  })
}


# IAM Role Policy Attachments

# EKS Cluster Role Policies
resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_vpc_resource_controller" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_worker_node_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.eks_cluster.name
}

resource "aws_iam_role_policy_attachment" "eks_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
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

resource "aws_iam_role_policy_attachment" "system_nodes_fsx_full_access" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonFSxFullAccess"
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

# Instance Type Profiles for EC2 instances
resource "aws_iam_instance_profile" "system_nodes" {
  name = "${local.prefix}-system-nodes"
  role = aws_iam_role.system_nodes.name

  tags = merge(local.config.deployment.tags, {
    Name = "${local.prefix}-system-nodes"
  })
}

resource "aws_iam_instance_profile" "worker_nodes" {
  name = "${local.prefix}-worker-nodes"
  role = aws_iam_role.worker_nodes.name

  tags = merge(local.config.deployment.tags, {
    Name = "${local.prefix}-worker-nodes"
  })
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

  tags = merge(local.config.deployment.tags, {
    Name = "${local.prefix}-cloudwatch-observability"
  })
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

  tags = merge(local.config.deployment.tags, {
    Name = "${local.prefix}-ebs-csi-driver"
  })
}

resource "aws_iam_role_policy_attachment" "ebs_csi_driver_policy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_driver.name
}
