# Toleration locals for DRY add-on configuration (#9)
locals {
  # Tolerations for system-only add-ons (coredns, metrics-server, ebs-csi controller)
  system_tolerations = [
    {
      key      = "dedicated"
      operator = "Equal"
      value    = "system-workload"
      effect   = "NoSchedule"
    },
    {
      key      = "dedicated"
      operator = "Equal"
      value    = "system-workload"
      effect   = "NoExecute"
    },
    {
      operator = "Exists"
    }
  ]

  # Tolerations for add-ons that run on all nodes (vpc-cni, cloudwatch agent)
  all_node_tolerations = [
    {
      key      = "dedicated"
      operator = "Equal"
      value    = "system-workload"
      effect   = "NoSchedule"
    },
    {
      key      = "dedicated"
      operator = "Equal"
      value    = "system-workload"
      effect   = "NoExecute"
    },
    {
      key      = "dedicated"
      operator = "Equal"
      value    = "worker-workload"
      effect   = "NoSchedule"
    },
    {
      key      = "dedicated"
      operator = "Equal"
      value    = "worker-workload"
      effect   = "NoExecute"
    },
    {
      operator = "Exists"
    }
  ]

  # #10: Normalize addon versions — empty string means latest (null)
  addon_versions = {
    for k, v in try(local.config.cluster.eks.addOns, {}) :
    k => v == "" ? null : v
  }
}

# KMS Key for EKS Secret Encryption
resource "aws_kms_key" "eks" {
  description             = "${local.prefix} EKS Secret Encryption Key"
  deletion_window_in_days = local.kms_deletion_window_days
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "Enable IAM User Permissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${local.account}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        Sid    = "Allow CloudWatch Logs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${local.region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:CreateGrant",
          "kms:DescribeKey"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${local.region}:${local.account}:log-group:*"
          }
        }
      }
    ]
  })

  # #5: Removed LastReconciled timestamp tag (caused drift every apply)
  tags = { Name = "${local.prefix}-eks-secrets" }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${local.prefix}-eks-secrets"
  target_key_id = aws_kms_key.eks.key_id
}

# CloudWatch Log Group for EKS Control Plane
resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/cluster/${local.prefix}-${local.cluster_name}"
  retention_in_days = local.log_retention_days
  kms_key_id        = aws_kms_key.eks.arn

  tags = { Name = "${local.prefix}-eks-control-plane-logs" }
}

# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = local.cluster_name
  version  = local.eks_version
  role_arn = aws_iam_role.eks_cluster.arn

  enabled_cluster_log_types = ["api", "authenticator", "audit", "scheduler", "controllerManager"]

  tags = { Name = local.cluster_name }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  kubernetes_network_config {
    service_ipv4_cidr = local.service_cidr
  }

  vpc_config {
    endpoint_private_access = true
    endpoint_public_access  = true
    subnet_ids              = local.system_subnet_ids

    public_access_cidrs = concat(
      try(local.config.cluster.eks.controlPlane.allowedCidrs, []),
      [local.egress_cidr],
    )

    security_group_ids = [
      aws_security_group.main["${local.prefix}-system"].id,
      aws_security_group.main["${local.prefix}-worker"].id
    ]
  }

  # #17: Keep only IAM policy + log group deps (cluster already refs KMS by attribute)
  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller,
    aws_cloudwatch_log_group.eks_cluster,
  ]
}

# EKS Access Entries
# System nodes use an EKS managed node group — access entry auto-created
resource "aws_eks_access_entry" "worker_nodes" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.worker_nodes.arn
  type          = "EC2_LINUX"

  tags = { Name = "${local.prefix}-worker-nodes-access" }
}

# EKS Access Entries for Admin Roles
# Supports two formats:
#   - Full ARN: arn:aws:iam::ACCOUNT:role/path/ROLE_NAME (used as-is)
#   - Role name: MyRole or AWSReservedSSO_* (looked up via IAM data source)
data "aws_iam_role" "admin_roles" {
  for_each = {
    for role in try(local.config.cluster.eks.adminRoles, []) :
    role => role if !startswith(role, "arn:")
  }
  name = each.value
}

locals {
  admin_role_arns = merge(
    # Roles looked up via data source (by name)
    { for k, v in data.aws_iam_role.admin_roles : k => v.arn },
    # Roles provided as full ARNs (used as-is)
    { for role in try(local.config.cluster.eks.adminRoles, []) : role => role if startswith(role, "arn:") }
  )
}

resource "aws_eks_access_entry" "admin_roles" {
  for_each = local.admin_role_arns

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = each.value
  type          = "STANDARD"

  tags = { Name = "${local.prefix}-${replace(each.key, "/[^a-zA-Z0-9-]/", "-")}-access" }
}

# #18: Only ClusterAdminPolicy (superset of EKSAdminPolicy — removed duplicate)
resource "aws_eks_access_policy_association" "admin_cluster_admin" {
  for_each = local.admin_role_arns

  cluster_name  = aws_eks_cluster.main.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = each.value

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin_roles]
}

# EKS Add-ons
resource "aws_eks_addon" "coredns" {
  count = try(local.config.cluster.eks.addOns.coreDns, null) != null ? 1 : 0

  addon_name                  = "coredns"
  addon_version               = try(local.addon_versions.coreDns, null)
  cluster_name                = aws_eks_cluster.main.name
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  configuration_values = jsonencode({
    tolerations = local.system_tolerations
    corefile    = <<-EOT
    .:53 {
        errors
        health {
            lameduck 5s
          }
        ready
        kubernetes cluster.local in-addr.arpa ip6.arpa {
          pods insecure
          fallthrough in-addr.arpa ip6.arpa
        }
        prometheus :9153
        forward . /etc/resolv.conf {
          except s8k.io
        }
        forward s8k.io 205.251.192.116 205.251.199.66 205.251.194.44 205.251.196.207
        cache 30
        loop
        reload
        loadbalance
    }
EOT
  })

  tags = { Name = "${local.prefix}-coredns" }
}

resource "aws_eks_addon" "vpc_cni" {
  count = try(local.config.cluster.eks.addOns.vpcCni, null) != null ? 1 : 0

  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  addon_version               = try(local.addon_versions.vpcCni, null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  configuration_values = jsonencode({
    tolerations         = local.all_node_tolerations
    enableNetworkPolicy = "true"
    init = {
      env = {
        DISABLE_TCP_EARLY_DEMUX = "true"
      }
    }
    env = {
      ENABLE_POD_ENI                     = "false"
      AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = "true"
      ENI_CONFIG_LABEL_DEF               = "topology.kubernetes.io/zone"
      POD_SECURITY_GROUP_ENFORCING_MODE  = "standard"
      AWS_VPC_K8S_CNI_EXTERNALSNAT       = "false"
      MINIMUM_IP_TARGET                  = local.vpc_cni_minimum_ip_target
      WARM_IP_TARGET                     = local.vpc_cni_warm_ip_target
    }
  })

  depends_on = [local_file.eniconfig]

  tags = { Name = "${local.prefix}-vpc-cni" }
}

resource "aws_eks_addon" "kube_proxy" {
  count = try(local.config.cluster.eks.addOns.kubeProxy, null) != null ? 1 : 0

  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  addon_version               = try(local.addon_versions.kubeProxy, null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  tags = { Name = "${local.prefix}-kube-proxy" }
}

resource "aws_eks_addon" "cloudwatch_observability" {
  count = try(local.config.cluster.eks.addOns.cloudwatchObservability, null) != null ? 1 : 0

  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "amazon-cloudwatch-observability"
  addon_version               = try(local.addon_versions.cloudwatchObservability, null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = aws_iam_role.cloudwatch_observability.arn

  configuration_values = jsonencode({
    manager = {
      tolerations = local.system_tolerations
    }
    agent = {
      name        = "cw-observability"
      tolerations = local.all_node_tolerations
    }
  })

  tags = { Name = "${local.prefix}-cloudwatch-observability" }
}

resource "aws_eks_addon" "metrics_server" {
  count = try(local.config.cluster.eks.addOns.metricsServer, null) != null ? 1 : 0

  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "metrics-server"
  addon_version               = try(local.addon_versions.metricsServer, null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    tolerations = local.system_tolerations
  })

  tags = { Name = "${local.prefix}-metrics-server" }
}

resource "aws_eks_addon" "ebs_csi_driver" {
  count = try(local.config.cluster.eks.addOns.ebsCsi, null) != null ? 1 : 0

  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = try(local.addon_versions.ebsCsi, null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = aws_iam_role.ebs_csi_driver.arn

  configuration_values = jsonencode({
    controller = {
      tolerations = local.system_tolerations
    }
  })

  tags = { Name = "${local.prefix}-ebs-csi-driver" }
}


data "tls_certificate" "oidc_provider" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "oidc_provider" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [data.tls_certificate.oidc_provider.certificates[0].sha1_fingerprint]

  tags = { Name = "${local.prefix}-oidc-provider" }
}
