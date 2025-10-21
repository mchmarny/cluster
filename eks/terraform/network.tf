locals {
  # Define subnets by type for easier processing in the VPC module
  subnets_by_type = {
    for name, group in local.config.network.subnets :
    name => {
      for _, cfg in group :
      "${local.prefix}-${name}-${cfg.zone}" => {
        availability_zone       = cfg.zone
        cidr_block              = cfg.cidr
        map_public_ip_on_launch = name == "public" ? true : false
      }
    }
  }

  subnet_ids_by_type = {
    for name, group in local.config.network.subnets :
    name => [
      for i, cfg in group :
      aws_subnet.main["${local.prefix}-${name}-${cfg.zone}"].id
    ]
  }

  system_subnet_ids = [
    for i, cfg in local.config.network.subnets.system :
    aws_subnet.main["${local.prefix}-system-${cfg.zone}"].id
  ]

}

# VPC
resource "aws_vpc" "main" {
  cidr_block           = local.config.network.cidrs.host
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = merge(local.config.deployment.tags, {
    Name = "${local.prefix}-vpc"
  })
}

# CloudWatch Log Group for VPC Flow Logs
resource "aws_cloudwatch_log_group" "vpc_flow_logs" {
  name              = "/aws/vpc/${local.prefix}-flow-logs"
  retention_in_days = local.vpcFlowLogRetentionInDays
  kms_key_id        = aws_kms_key.eks.arn

  tags = merge(local.config.deployment.tags, {
    Name = "${local.prefix}-vpc-flow-logs"
  })
}

# IAM Role for VPC Flow Logs
resource "aws_iam_role" "vpc_flow_logs" {
  name               = "${local.prefix}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.vpc_flow_logs_assume_role.json

  tags = merge(local.config.deployment.tags, {
    Name = "${local.prefix}-vpc-flow-logs"
  })
}

data "aws_iam_policy_document" "vpc_flow_logs_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role_policy_attachment" "vpc_flow_logs" {
  policy_arn = aws_iam_policy.flow_log.arn
  role       = aws_iam_role.vpc_flow_logs.name
}

# VPC Flow Log
resource "aws_flow_log" "main" {
  iam_role_arn    = aws_iam_role.vpc_flow_logs.arn
  log_destination = aws_cloudwatch_log_group.vpc_flow_logs.arn
  traffic_type    = "ALL"
  vpc_id          = aws_vpc.main.id

  tags = merge(local.config.deployment.tags, {
    Name = "${local.prefix}-vpc-flow-log"
  })
}

resource "aws_vpc_ipv4_cidr_block_association" "secondary_cidr" {
  vpc_id     = aws_vpc.main.id
  cidr_block = local.config.network.cidrs.pod
}

# Subnets
resource "aws_subnet" "main" {
  for_each = merge(values(local.subnets_by_type)...)

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.value.availability_zone
  cidr_block              = each.value.cidr_block
  map_public_ip_on_launch = each.value.map_public_ip_on_launch

  tags = merge(local.config.deployment.tags, {
    Name = "${each.key}-subnet"
    # AWS Load Balancer Controller tags
    "kubernetes.io/role/elb"                             = contains(split("-", each.key), "public") ? "1" : null
    "kubernetes.io/role/internal-elb"                    = contains(split("-", each.key), "system") || contains(split("-", each.key), "worker") ? "1" : null
    "kubernetes.io/cluster/${local.config.cluster.name}" = "shared"
  })

  depends_on = [
    aws_vpc_ipv4_cidr_block_association.secondary_cidr
  ]
}

# Internet Gateway
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = merge(local.config.deployment.tags, {
    Name = "${local.prefix}-igw"
  })
}

# Elastic IPs for NAT Gateways
resource "aws_eip" "nat" {
  for_each = {
    for i, subnet in local.config.network.subnets.public :
    "${local.prefix}-eip-${i}" => subnet
  }

  domain = "vpc"

  tags = merge(local.config.deployment.tags, {
    Name = each.key
  })
}

# NAT Gateways
resource "aws_nat_gateway" "main" {
  for_each = {
    for i, subnet in local.config.network.subnets.public :
    "${local.prefix}-nat-${i}" => {
      subnet_id     = aws_subnet.main["${local.prefix}-public-${subnet.zone}"].id
      allocation_id = aws_eip.nat["${local.prefix}-eip-${i}"].id
    }
  }

  subnet_id     = each.value.subnet_id
  allocation_id = each.value.allocation_id

  tags = merge(local.config.deployment.tags, {
    Name = each.key
  })

  depends_on = [aws_internet_gateway.main]
}

# Route Tables
resource "aws_route_table" "public" {
  for_each = {
    for i, subnet in local.config.network.subnets.public :
    "${local.prefix}-public-rt-${i}" => subnet
  }

  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.config.deployment.tags, {
    Name = each.key
  })
}

resource "aws_route_table" "private_system" {
  for_each = {
    for i, subnet in local.config.network.subnets.system :
    "${local.prefix}-system-rt-${i}" => {
      subnet         = subnet
      nat_gateway_id = aws_nat_gateway.main["${local.prefix}-nat-${i}"].id
    }
  }

  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = each.value.nat_gateway_id
  }

  tags = merge(local.config.deployment.tags, {
    Name = each.key
  })
}

resource "aws_route_table" "private_worker" {
  for_each = {
    for i, subnet in local.config.network.subnets.worker :
    "${local.prefix}-worker-rt-${i}" => {
      subnet         = subnet
      nat_gateway_id = aws_nat_gateway.main["${local.prefix}-nat-${i}"].id
    }
  }

  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = each.value.nat_gateway_id
  }

  tags = merge(local.config.deployment.tags, {
    Name = each.key
  })
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  for_each = {
    for i, subnet in local.config.network.subnets.public :
    "${local.prefix}-public-${subnet.zone}" => {
      subnet_id      = aws_subnet.main["${local.prefix}-public-${subnet.zone}"].id
      route_table_id = aws_route_table.public["${local.prefix}-public-rt-${i}"].id
    }
  }

  subnet_id      = each.value.subnet_id
  route_table_id = each.value.route_table_id
}

resource "aws_route_table_association" "system" {
  for_each = {
    for i, subnet in local.config.network.subnets.system :
    "${local.prefix}-system-${subnet.zone}" => {
      subnet_id      = aws_subnet.main["${local.prefix}-system-${subnet.zone}"].id
      route_table_id = aws_route_table.private_system["${local.prefix}-system-rt-${i}"].id
    }
  }

  subnet_id      = each.value.subnet_id
  route_table_id = each.value.route_table_id
}

resource "aws_route_table_association" "worker" {
  for_each = {
    for i, subnet in local.config.network.subnets.worker :
    "${local.prefix}-worker-${subnet.zone}" => {
      subnet_id      = aws_subnet.main["${local.prefix}-worker-${subnet.zone}"].id
      route_table_id = aws_route_table.private_worker["${local.prefix}-worker-rt-${i}"].id
    }
  }

  subnet_id      = each.value.subnet_id
  route_table_id = each.value.route_table_id
}

# Ensure traffic for these services resolves to an endpoint in the VPC
locals {
  endpoint_subnets = flatten([
    for name, group in local.config.network.subnets :
    [
      for i, cfg in group :
      "${local.prefix}-${name}-${cfg.zone}"
      if(name == "system" || (name == "worker" && try(cfg.disableEndpoints, false) != true))
    ]
  ])
}

resource "aws_vpc_endpoint" "services" {
  for_each = { for service in local.config.network.endpoints : service => service }

  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${local.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true

  dns_options {
    dns_record_ip_type = "ipv4"
  }

  subnet_ids = [
    for name in local.endpoint_subnets :
    aws_subnet.main[name].id
  ]

  security_group_ids = [
    aws_security_group.main["${local.prefix}-system"].id,
    aws_security_group.main["${local.prefix}-worker"].id,
  ]

  tags = merge(local.config.deployment.tags, {
    Name = "${local.prefix}-vpce-${each.value}"
  })
}

resource "local_file" "eniconfig" {
  filename        = "${path.module}/eni-config.yaml"
  file_permission = "0644"
  content = templatefile("${path.module}/templates/eni-config.ytpl", {
    subnets = flatten([
      for name, group in local.config.network.subnets : [
        for _, cfg in group : {
          name = cfg.zone # Use zone name directly to match ENI_CONFIG_LABEL_DEF
          sg   = aws_security_group.main["${local.prefix}-${name}"].id
          id   = aws_subnet.main["${local.prefix}-${name}-${cfg.zone}"].id
        }
        if name == "system" || name == "worker"
      ]
    ])
  })

  provisioner "local-exec" {
    command = <<-EOC
      set -euo pipefail
      aws eks update-kubeconfig --region ${local.region} --name ${aws_eks_cluster.main.name}
      kubectl apply -f ${self.filename}
      rm -f ${self.filename}
    EOC
  }

  depends_on = [
    aws_eks_cluster.main
  ]
}
