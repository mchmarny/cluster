data "aws_caller_identity" "current" {}

# Instance type metadata for worker nodes (used to determine EFA network card count)
data "aws_ec2_instance_type" "worker" {
  for_each = {
    for ng in try(local.worker_node_groups, []) : ng.name => ng.instanceType
  }
  instance_type = each.value
}

# Query available AZs for default subnet generation
data "aws_availability_zones" "available" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}
data "http" "egress_ip" {
  url             = "https://checkip.amazonaws.com"
  request_headers = { Accept = "text/plain" }
}

# Ubuntu EKS Worker AMI lookup (used when imageId is not specified)
# https://cloud-images.ubuntu.com/docs/aws/eks/
# Only looks up architectures that are actually needed by node groups
locals {
  needed_architectures = toset([
    for ng in local.worker_node_groups :
    try(ng.architecture, "x86_64")
    if try(ng.imageId, null) == null
  ])
}

data "aws_ami" "ubuntu_eks" {
  for_each = local.needed_architectures

  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu-eks/k8s_${local.eks_version_for_ami}/images/*"]
  }

  filter {
    name   = "architecture"
    values = [each.value]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

locals {
  // Load configuration from YAML file
  config = yamldecode(file(var.CONFIG_PATH))

  config_dir       = dirname(var.CONFIG_PATH)
  config_filename  = basename(var.CONFIG_PATH)
  config_basename  = replace(local.config_filename, "/\\.ya?ml$/", "")
  status_file_path = "${local.config_dir}/${local.config_basename}-status.json"

  // Extract required deployment settings
  prefix      = local.config.deployment.id
  region      = local.config.deployment.location
  account     = local.config.deployment.tenancy // AWS account ID (consistent with other CSPs)
  egress_cidr = "${trimspace(data.http.egress_ip.response_body)}/32"

  // Extract optional deployment settings with defaults
  eks_version  = try(local.config.cluster.eks.version, null)
  cluster_name = try(local.config.cluster.eks.name, local.prefix)

  // EKS version for AMI lookup (must be specified for Ubuntu AMI auto-selection)
  eks_version_for_ami = local.eks_version

  // VPC CNI custom networking gate
  vpc_cni_enabled = try(local.config.cluster.eks.addOns.vpcCni, null) != null

  // Network defaults
  vpc_cidr     = try(local.config.network.eks.cidrs.host, "10.0.0.0/16")
  pod_cidr     = try(local.config.network.eks.cidrs.pod, "100.65.0.0/16")
  service_cidr = try(local.config.cluster.eks.controlPlane.cidr, "172.20.0.0/16")

  // Default VPC endpoints for private clusters
  default_endpoints = ["s3", "ssm", "ec2messages", "ssmmessages", "logs"]
  vpc_endpoints     = try(local.config.network.eks.endpoints, local.default_endpoints)

  // Observability
  log_retention_days          = try(local.config.observability.logRetentionInDays, 7)
  vpc_flow_log_retention_days = try(local.config.observability.vpcFlowLogs.retentionInDays, 7)
  metrics_granularity         = try(local.config.observability.metrics.granularity, "1Minute")

  // Security
  kms_deletion_window_days = try(local.config.security.kms.deletionWindowInDays, 30)

  // Networking
  vpc_cni_minimum_ip_target = tostring(try(local.config.networking.vpcCni.minimumIpTarget, 30))
  vpc_cni_warm_ip_target    = tostring(try(local.config.networking.vpcCni.warmIpTarget, 20))

  // ASG Configuration
  asg_health_check_grace_period = try(local.config.compute.eks.autoscaling.healthCheck.gracePeriod, 300)
  asg_capacity_timeout          = try(local.config.compute.eks.autoscaling.capacityTimeout, "10m")
  asg_delete_timeout            = try(local.config.compute.eks.autoscaling.deleteTimeout, "30m")
  asg_min_healthy_percentage    = try(local.config.compute.eks.autoscaling.instanceRefresh.minHealthyPercentage, 90)
  asg_instance_warmup           = try(local.config.compute.eks.autoscaling.instanceRefresh.instanceWarmup, 300)
  asg_checkpoint_percentages    = try(local.config.compute.eks.autoscaling.instanceRefresh.checkpointPercentages, [50, 100])

  // Storage
  block_volume_mount_default = "/dev/sda1" // Default mount point if not specified
  block_volume_type_default  = "gp3"       // Default volume type if not specified
  block_volume_size_default  = 50          // Default volume size in GB if not specified

  // Use first 2 AZs for default subnets
  available_azs = slice(data.aws_availability_zones.available.names, 0,
  min(2, length(data.aws_availability_zones.available.names)))

  // Default subnets (auto-computed from VPC CIDR)
  default_subnets = {
    public = [for i, az in local.available_azs : {
      cidr = cidrsubnet(local.vpc_cidr, 11, i) # /27 (32 IPs)
      zone = az
    }]
    system = [for i, az in local.available_azs : {
      cidr = cidrsubnet(local.vpc_cidr, 6, i + 1) # /22 (1024 IPs)
      zone = az
    }]
    worker = [for i, az in local.available_azs : {
      cidr = cidrsubnet(local.vpc_cidr, 2, i + 2) # /18 (16384 IPs each)
      zone = az
    }]
    pod = [for i, az in local.available_azs : {
      cidr = cidrsubnet(local.pod_cidr, 2, i) # /18 from secondary CIDR
      zone = az
    }]
  }

  // Effective config: user config if provided, otherwise defaults
  _raw_subnets = try(local.config.network.eks.subnets, null) != null ? local.config.network.eks.subnets : local.default_subnets
  effective_subnets = merge(
    { for k, v in local._raw_subnets : k => v if k != "pod" },
    { pod = local.vpc_cni_enabled ? try(local._raw_subnets.pod, local.default_subnets.pod) : [] }
  )
  effective_tags = try(local.config.deployment.tags, {})

  // Stable identity tags applied to every taggable resource via default_tags.
  // Used by tools/delete-eks for tag-based discovery of orphaned resources.
  common_tags = {
    Cluster   = local.prefix
    ManagedBy = "cluster-toolkit"
  }
}
