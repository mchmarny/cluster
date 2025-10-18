locals {
  security_groups = {

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
        "kubernetes.io/cluster/${local.config.cluster.name}" = "owned"
      }
      ingress = [
        {
          description = "Allow all traffic within system nodes"
          from_port   = 0
          to_port     = 0
          protocol    = "-1"
          self        = true
        },
        {
          description = "Allow HTTPS traffic from worker nodes and EKS control plane"
          from_port   = 443
          to_port     = 443
          protocol    = "tcp"
          cidr_blocks = [
            local.config.network.cidrs.host,
            local.config.network.cidrs.pod,
            local.config.cluster.controlPlane.cidr,
          ]
        },
        {
          description = "Allow kubelet API from EKS control plane"
          from_port   = 10250
          to_port     = 10250
          protocol    = "tcp"
          cidr_blocks = [
            local.config.cluster.controlPlane.cidr,
          ]
        },
        {
          description = "Allow kubelet traffic from all nodes and pods"
          from_port   = 10250
          to_port     = 10250
          protocol    = "tcp"
          cidr_blocks = [
            local.config.network.cidrs.host,
            local.config.network.cidrs.pod,
          ]
        },
        {
          description = "Allow DNS TCP from all nodes and pods"
          from_port   = 53
          to_port     = 53
          protocol    = "tcp"
          cidr_blocks = [
            local.config.network.cidrs.host,
            local.config.network.cidrs.pod,
          ]
        },
        {
          description = "Allow DNS UDP from all nodes and pods"
          from_port   = 53
          to_port     = 53
          protocol    = "udp"
          cidr_blocks = [
            local.config.network.cidrs.host,
            local.config.network.cidrs.pod,
          ]
        },
        {
          description = "Allow Node Feature Discovery traffic"
          from_port   = 8080
          to_port     = 8080
          protocol    = "tcp"
          cidr_blocks = [
            local.config.network.cidrs.host,
            local.config.network.cidrs.pod,
          ]
        },
        {
          description = "Allow NodePort services from public subnet"
          from_port   = 30000
          to_port     = 32767
          protocol    = "tcp"
          cidr_blocks = [
            for subnet in local.config.network.subnets.public : subnet.cidr
          ]
        },
      ]
      egress = [
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
        }
      ]
    }

    # Pod
    ("${local.prefix}-pod") = {
      tags = {
        "kubernetes.io/cluster/${local.config.cluster.name}" = "owned"
      }
      ingress = [
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
            local.config.network.cidrs.host,
          ]
        },
        {
          description = "Allow all UDP from VPC"
          from_port   = 0
          to_port     = 65535
          protocol    = "udp"
          cidr_blocks = [
            local.config.network.cidrs.host,
          ]
        },
      ]
      egress = [
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
        }
      ]
    }

    # Worker
    ("${local.prefix}-worker") = {
      tags = {
        "kubernetes.io/cluster/${local.config.cluster.name}" = "owned"
      }
      ingress = [
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
            for subnet in local.config.network.subnets.system : subnet.cidr
          ]
        },
        {
          description = "Allow kubelet API from EKS control plane"
          from_port   = 10250
          to_port     = 10250
          protocol    = "tcp"
          cidr_blocks = [
            local.config.cluster.controlPlane.cidr,
          ]
        },
        {
          description = "Allow kubelet traffic from all nodes and pods"
          from_port   = 10250
          to_port     = 10250
          protocol    = "tcp"
          cidr_blocks = [
            local.config.network.cidrs.host,
            local.config.network.cidrs.pod,
          ]
        },
        {
          description = "Allow HTTPS traffic from all nodes, pods, and control plane"
          from_port   = 443
          to_port     = 443
          protocol    = "tcp"
          cidr_blocks = [
            local.config.network.cidrs.host,
            local.config.network.cidrs.pod,
            local.config.cluster.controlPlane.cidr,
          ]
        },
        {
          description = "Allow DNS TCP from all nodes and pods"
          from_port   = 53
          to_port     = 53
          protocol    = "tcp"
          cidr_blocks = [
            local.config.network.cidrs.host,
            local.config.network.cidrs.pod,
          ]
        },
        {
          description = "Allow DNS UDP from all nodes and pods"
          from_port   = 53
          to_port     = 53
          protocol    = "udp"
          cidr_blocks = [
            local.config.network.cidrs.host,
            local.config.network.cidrs.pod,
          ]
        },
        {
          description = "Allow NodePort services from public subnet"
          from_port   = 30000
          to_port     = 32767
          protocol    = "tcp"
          cidr_blocks = [
            for subnet in local.config.network.subnets.public : subnet.cidr
          ]
        },
      ]
      egress = [
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
    }
  }
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

  tags = merge(local.config.deployment.tags, try(each.value.tags, {}), {
    Name = each.key
  })
}