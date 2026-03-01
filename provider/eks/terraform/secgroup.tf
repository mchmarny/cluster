locals {
  # CIDR block helpers: include pod_cidr only when VPC CNI custom networking is enabled
  node_cidr_blocks     = compact(concat([local.vpc_cidr, local.service_cidr], local.vpc_cni_enabled ? [local.pod_cidr] : []))
  node_pod_cidr_blocks = compact(concat([local.vpc_cidr], local.vpc_cni_enabled ? [local.pod_cidr] : []))

  # #14: Shared ingress rules for both system and worker SGs
  shared_node_ingress = [
    {
      description = "Allow HTTPS traffic from all nodes, pods, and control plane"
      from_port   = 443
      to_port     = 443
      protocol    = "tcp"
      cidr_blocks = local.node_cidr_blocks
    },
    {
      description = "Allow kubelet API from EKS control plane"
      from_port   = 10250
      to_port     = 10250
      protocol    = "tcp"
      cidr_blocks = [
        local.service_cidr,
      ]
    },
    {
      description = "Allow kubelet traffic from all nodes and pods"
      from_port   = 10250
      to_port     = 10250
      protocol    = "tcp"
      cidr_blocks = local.node_pod_cidr_blocks
    },
    {
      description = "Allow DNS TCP from all nodes and pods"
      from_port   = 53
      to_port     = 53
      protocol    = "tcp"
      cidr_blocks = local.node_pod_cidr_blocks
    },
    {
      description = "Allow DNS UDP from all nodes and pods"
      from_port   = 53
      to_port     = 53
      protocol    = "udp"
      cidr_blocks = local.node_pod_cidr_blocks
    },
    {
      description = "Allow NodePort services from public subnet"
      from_port   = 30000
      to_port     = 32767
      protocol    = "tcp"
      cidr_blocks = [
        for subnet in local.effective_subnets.public : subnet.cidr
      ]
    },
  ]

  shared_node_egress = [
    {
      description = "Allow all outbound traffic to self"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      self        = true
    },
    {
      description = "Allow all outbound traffic to internet"
      from_port   = 0
      to_port     = 0
      protocol    = "-1"
      cidr_blocks = ["0.0.0.0/0"]
    },
  ]

  # #14: Config-driven additional SG rules
  additional_sg_rules = try(local.config.network.securityGroups.additionalRules, [])

  additional_ingress_by_target = {
    for target in(local.vpc_cni_enabled ? ["system", "worker", "pod"] : ["system", "worker"]) :
    target => [
      for rule in local.additional_sg_rules : {
        description = try(rule.description, "Custom rule")
        from_port   = rule.fromPort
        to_port     = rule.toPort
        protocol    = rule.protocol
        cidr_blocks = try(rule.cidrBlocks, [])
      }
      if rule.target == target && rule.direction == "ingress"
    ]
  }

  additional_egress_by_target = {
    for target in(local.vpc_cni_enabled ? ["system", "worker", "pod"] : ["system", "worker"]) :
    target => [
      for rule in local.additional_sg_rules : {
        description = try(rule.description, "Custom rule")
        from_port   = rule.fromPort
        to_port     = rule.toPort
        protocol    = rule.protocol
        cidr_blocks = try(rule.cidrBlocks, [])
      }
      if rule.target == target && rule.direction == "egress"
    ]
  }

  security_groups = merge(
    {
      ("${local.prefix}-efa") = {
        description = "https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/efa-start.html#efa-start-security"
        ingress = [
          {
            from_port = 0
            to_port   = 0
            protocol  = "-1"
            self      = true
          }
        ]
        egress = [
          {
            from_port = 0
            to_port   = 0
            protocol  = "-1"
            self      = true
          }
        ]
      }

      # System nodes
      ("${local.prefix}-system") = {
        tags = {
          "kubernetes.io/cluster/${local.cluster_name}" = "owned"
        }
        ingress = concat(
          [
            {
              description = "Allow all traffic within system nodes"
              from_port   = 0
              to_port     = 0
              protocol    = "-1"
              self        = true
            },
            {
              description = "Allow Node Feature Discovery traffic"
              from_port   = 8080
              to_port     = 8080
              protocol    = "tcp"
              cidr_blocks = local.node_pod_cidr_blocks
            },
          ],
          local.shared_node_ingress,
          local.additional_ingress_by_target["system"],
        )
        egress = concat(
          local.shared_node_egress,
          local.additional_egress_by_target["system"],
        )
      }

      # Worker
      ("${local.prefix}-worker") = {
        tags = {
          "kubernetes.io/cluster/${local.cluster_name}" = "owned"
        }
        ingress = concat(
          [
            {
              description = "Allow all traffic within worker nodes"
              from_port   = 0
              to_port     = 0
              protocol    = "-1"
              self        = true
            },
            {
              description = "Allow all traffic from system nodes"
              from_port   = 0
              to_port     = 0
              protocol    = "-1"
              cidr_blocks = [
                for subnet in local.effective_subnets.system : subnet.cidr
              ]
            },
          ],
          local.shared_node_ingress,
          local.additional_ingress_by_target["worker"],
        )
        egress = concat(
          local.shared_node_egress,
          local.additional_egress_by_target["worker"],
        )
      }
    },
    local.vpc_cni_enabled ? {
      # Pod (VPC CNI custom networking only)
      ("${local.prefix}-pod") = {
        tags = {
          "kubernetes.io/cluster/${local.cluster_name}" = "owned"
        }
        ingress = concat(
          [
            {
              description = "Allow all traffic within pod security group"
              from_port   = 0
              to_port     = 0
              protocol    = "-1"
              self        = true
            },
            {
              description = "Allow all TCP from VPC"
              from_port   = 0
              to_port     = 65535
              protocol    = "tcp"
              cidr_blocks = [
                local.vpc_cidr,
              ]
            },
            {
              description = "Allow all UDP from VPC"
              from_port   = 0
              to_port     = 65535
              protocol    = "udp"
              cidr_blocks = [
                local.vpc_cidr,
              ]
            },
          ],
          local.additional_ingress_by_target["pod"],
        )
        egress = concat(
          local.shared_node_egress,
          local.additional_egress_by_target["pod"],
        )
      }
    } : {}
  )
}



# Security Groups
resource "aws_security_group" "main" {
  for_each = local.security_groups

  name        = each.key
  description = try(each.value.description, "Security group for ${each.key}")
  vpc_id      = aws_vpc.main.id

  dynamic "ingress" {
    for_each = try(each.value.ingress, [])
    content {
      from_port       = ingress.value.from_port
      to_port         = ingress.value.to_port
      protocol        = ingress.value.protocol
      cidr_blocks     = try(ingress.value.cidr_blocks, [])
      security_groups = try(ingress.value.security_groups, [])
      self            = try(ingress.value.self, false)
      description     = try(ingress.value.description, "")
    }
  }

  dynamic "egress" {
    for_each = try(each.value.egress, [])
    content {
      from_port       = egress.value.from_port
      to_port         = egress.value.to_port
      protocol        = egress.value.protocol
      cidr_blocks     = try(egress.value.cidr_blocks, [])
      security_groups = try(egress.value.security_groups, [])
      self            = try(egress.value.self, false)
      description     = try(egress.value.description, "")
    }
  }

  # Keep merge for k8s tags (non-default per-SG tags)
  tags = merge(try(each.value.tags, {}), {
    Name = each.key
  })
}
