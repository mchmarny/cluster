# KMS Key for EKS Secret Encryption
resource "aws_kms_key" "eks" {
  description             = "${local.prefix} EKS Secret Encryption Key"
  deletion_window_in_days = local.kmsDeletionWindowInDays
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

  tags = merge(local.config.deployment.tags, {
    Name           = "${local.prefix}-eks-secrets",
    LastReconciled = local.updateTime,
  })
}

resource "aws_kms_alias" "eks" {
  name          = "alias/${local.prefix}-eks-secrets"
  target_key_id = aws_kms_key.eks.key_id
}

# CloudWatch Log Group for EKS Control Plane
resource "aws_cloudwatch_log_group" "eks_cluster" {
  name              = "/aws/eks/cluster/${local.prefix}-${local.config.cluster.name}"
  retention_in_days = local.logRetentionInDays
  kms_key_id        = aws_kms_key.eks.arn

  tags = merge(local.config.deployment.tags, {
    Name = "${local.prefix}-eks-control-plane-logs"
  })
}

# EKS Cluster
resource "aws_eks_cluster" "main" {
  name     = local.config.cluster.name
  version  = local.eks_version
  role_arn = aws_iam_role.eks_cluster.arn

  enabled_cluster_log_types = ["api", "authenticator", "audit", "scheduler", "controllerManager"]

  tags = merge({ Name = local.config.cluster.name }, local.config.deployment.tags)

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
    service_ipv4_cidr = local.config.cluster.controlPlane.cidr
  }

  vpc_config {
    endpoint_private_access = true
    endpoint_public_access  = true
    subnet_ids              = local.system_subnet_ids

    public_access_cidrs = concat(
      local.config.cluster.controlPlane.allowedCidrs,
      [local.egress_cidr],
    )

    security_group_ids = [
      aws_security_group.main["${local.prefix}-system"].id,
      aws_security_group.main["${local.prefix}-worker"].id
    ]
  }

  depends_on = [
    aws_iam_role_policy_attachment.eks_cluster_policy,
    aws_iam_role_policy_attachment.eks_vpc_resource_controller,
    aws_cloudwatch_log_group.eks_cluster,
    aws_kms_key.eks
  ]
}

# EKS Access Entries
resource "aws_eks_access_entry" "system_nodes" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.system_nodes.arn
  type          = "EC2_LINUX"

  tags = merge({ Name = "${local.prefix}-system-nodes-access" }, local.config.deployment.tags)
}

resource "aws_eks_access_entry" "worker_nodes" {
  cluster_name  = aws_eks_cluster.main.name
  principal_arn = aws_iam_role.worker_nodes.arn
  type          = "EC2_LINUX"

  tags = merge({ Name = "${local.prefix}-worker-nodes-access" }, local.config.deployment.tags)
}

# EKS Access Entries for Admin Roles
resource "aws_eks_access_entry" "admin_roles" {
  for_each = toset(try(local.config.cluster.adminRoles, []))

  cluster_name  = aws_eks_cluster.main.name
  principal_arn = "arn:aws:iam::${local.config.deployment.account}:role/${each.value}"
  type          = "STANDARD"

  tags = merge({ Name = "${local.prefix}-${each.value}-access" }, local.config.deployment.tags)
}

# EKS Access Policy Associations
resource "aws_eks_access_policy_association" "admin_cluster_admin" {
  for_each = toset(try(local.config.cluster.adminRoles, []))

  cluster_name  = aws_eks_cluster.main.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
  principal_arn = "arn:aws:iam::${local.config.deployment.account}:role/${each.value}"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin_roles]
}

resource "aws_eks_access_policy_association" "admin_eks_admin" {
  for_each = toset(try(local.config.cluster.adminRoles, []))

  cluster_name  = aws_eks_cluster.main.name
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSAdminPolicy"
  principal_arn = "arn:aws:iam::${local.config.deployment.account}:role/${each.value}"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin_roles]
}

# EKS Add-ons
resource "aws_eks_addon" "coredns" {
  count = try(local.config.cluster.addOns.coreDns, null) != null ? 1 : 0

  addon_name                  = "coredns"
  addon_version               = try(local.config.cluster.addOns.coreDns, null) == "" ? null : try(local.config.cluster.addOns.coreDns, null)
  cluster_name                = aws_eks_cluster.main.name
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  configuration_values = jsonencode({
    tolerations = [
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
    corefile = <<-EOT
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

  tags = merge({ Name = "${local.prefix}-coredns" }, local.config.deployment.tags)

  depends_on = [
    aws_eks_cluster.main
  ]
}

resource "aws_eks_addon" "vpc_cni" {
  count = try(local.config.cluster.addOns.vpcCni, null) != null ? 1 : 0

  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "vpc-cni"
  addon_version               = try(local.config.cluster.addOns.vpcCni, null) == "" ? null : try(local.config.cluster.addOns.vpcCni, null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  configuration_values = jsonencode({
    tolerations = [
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
        # Required: Allow CNI to run on nodes that are not yet ready
        operator = "Exists"
      }
    ]
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
      MINIMUM_IP_TARGET                  = local.vpcCniMinimumIpTarget
      WARM_IP_TARGET                     = local.vpcCniWarmIpTarget
    }
  })

  depends_on = [
    aws_eks_cluster.main,
    local_file.eniconfig
  ]

  tags = merge({ Name = "${local.prefix}-vpc-cni" }, local.config.deployment.tags)
}

resource "aws_eks_addon" "kube_proxy" {
  count = try(local.config.cluster.addOns.kubeProxy, null) != null ? 1 : 0

  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "kube-proxy"
  addon_version               = try(local.config.cluster.addOns.kubeProxy, null) == "" ? null : try(local.config.cluster.addOns.kubeProxy, null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_cluster.main
  ]

  tags = merge({ Name = "${local.prefix}-kube-proxy" }, local.config.deployment.tags)
}

resource "aws_eks_addon" "cloudwatch_observability" {
  count = try(local.config.cluster.addOns.cloudwatchObservability, null) != null ? 1 : 0

  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "amazon-cloudwatch-observability"
  addon_version               = try(local.config.cluster.addOns.cloudwatchObservability, null) == "" ? null : try(local.config.cluster.addOns.cloudwatchObservability, null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = aws_iam_role.cloudwatch_observability.arn

  configuration_values = jsonencode({
    manager = {
      tolerations = [
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
    }
    agent = {
      name = "cw-observability"
      tolerations = [
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
    }
  })

  depends_on = [
    aws_eks_cluster.main,
    aws_iam_role.cloudwatch_observability
  ]

  tags = merge({ Name = "${local.prefix}-cloudwatch-observability" }, local.config.deployment.tags)
}

resource "aws_eks_addon" "metrics_server" {
  count = try(local.config.cluster.addOns.metricsServer, null) != null ? 1 : 0

  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "metrics-server"
  addon_version               = try(local.config.cluster.addOns.metricsServer, null) == "" ? null : try(local.config.cluster.addOns.metricsServer, null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  configuration_values = jsonencode({
    tolerations = [
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
  })

  depends_on = [
    aws_eks_cluster.main
  ]

  tags = merge({ Name = "${local.prefix}-metrics-server" }, local.config.deployment.tags)
}

resource "aws_eks_addon" "ebs_csi_driver" {
  count = try(local.config.cluster.addOns.ebsCsi, null) != null ? 1 : 0

  cluster_name                = aws_eks_cluster.main.name
  addon_name                  = "aws-ebs-csi-driver"
  addon_version               = try(local.config.cluster.addOns.ebsCsi, null) == "" ? null : try(local.config.cluster.addOns.ebsCsi, null)
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  service_account_role_arn    = aws_iam_role.ebs_csi_driver.arn

  configuration_values = jsonencode({
    controller = {
      tolerations = [
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
    }
  })

  depends_on = [
    aws_eks_cluster.main,
    aws_iam_role.ebs_csi_driver
  ]

  tags = merge({ Name = "${local.prefix}-ebs-csi-driver" }, local.config.deployment.tags)
}


data "tls_certificate" "oidc_provider" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "oidc_provider" {
  url = aws_eks_cluster.main.identity[0].oidc[0].issuer

  client_id_list = ["sts.amazonaws.com"]

  thumbprint_list = [data.tls_certificate.oidc_provider.certificates[0].sha1_fingerprint]

  tags = merge({ Name = "${local.prefix}-oidc-provider" }, local.config.deployment.tags)

  depends_on = [
    aws_eks_cluster.main
  ]
}
