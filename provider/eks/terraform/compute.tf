locals {
  # Worker node groups (self-managed via launch template + ASG)
  # System nodes use an EKS managed node group — see aws_eks_node_group.system
  worker_node_groups = [
    for worker in try(local.config.compute.eks.nodeGroups.workers, []) :
    merge(worker, { type = "worker", subnet = "worker" })
  ]

  # Prepare node group labels and taints for use in user data scripts
  node_group_labels = {
    for ng in local.worker_node_groups :
    ng.name => join(
      ",",
      [for k, v in try(ng.labels, {}) : "${k}=${v}"]
    )
  }

  # Default worker taints plus optional per-group taints from config.
  # The default dedicated=worker-workload taint is applied only to GPU pools
  # (gpu_family != "na"): an accelerator is set or the instance type resolves to
  # a known GPU family. Non-GPU (CPU) worker pools come out untainted, matching
  # the GKE and AKS providers, which taint only their GPU pools. An empty result
  # renders as `--register-with-taints=` in user-data, i.e. no taints.
  default_worker_taints = "dedicated=worker-workload:NoSchedule,dedicated=worker-workload:NoExecute"
  node_group_taints = {
    for ng in local.worker_node_groups :
    ng.name => join(",", concat(
      local.gpu_family[ng.name] != "na" ? [local.default_worker_taints] : [],
      [for t in try(ng.taints, []) : "${t.key}=${t.value}:${t.effect}"]
    ))
  }

  # Config taints use Kubernetes-native effect names; the EKS managed node
  # group API requires its own enum
  taint_effect_api = {
    NoSchedule       = "NO_SCHEDULE"
    PreferNoSchedule = "PREFER_NO_SCHEDULE"
    NoExecute        = "NO_EXECUTE"
  }

  # Map instance family (the full prefix before ".") to GPU family for EFA
  # interface layout. GB200 needs its dedicated layout below; families not
  # listed here fall through to the generic all-cards branch, which is
  # correct for other GPU types (p5/H100, p5e/p5en/H200, p6-b200/B200).
  gpu_family = {
    for ng in local.worker_node_groups :
    ng.name => coalesce(
      try(ng.accelerator, null),
      try({
        "p5"         = "h100"
        "p6e-gb200"  = "gb200"
        "p6e-gb300"  = "gb300"
        "p6e-gb300r" = "gb300"
      }[split(".", ng.instanceType)[0]], null),
      "na"
    )
  }

  # Per-node-group EFA network interfaces
  # GB300: p6e-gb300r.36xlarge (GB300 NVL72 slice) exposes only network card 0;
  #   the EC2 API reports cards 1-8 with MaximumNetworkInterfaces=0, so a real
  #   ASG launch rejects any interface on those cards ("ENI limits exceeded on
  #   Network Card 1"). run-instances --dry-run does NOT enforce the per-card
  #   limit and gives false positives, so it must not be trusted here. The only
  #   valid layout is a single EFA on card 0: primary interface at device_index
  #   0 plus one efa-only at device_index 1.
  # GB200: AWS-recommended card indices (0, 1, 5, 9, 13)
  # GPU (h100 etc.): all network cards, count from instance type data source
  # Non-GPU: no EFA interfaces
  efa_network_interfaces = {
    for ng in local.worker_node_groups :
    ng.name => (
      local.gpu_family[ng.name] == "gb300" ? [
        {
          associate_public_ip_address = false
          delete_on_termination       = true
          device_index                = 0
          interface_type              = "interface"
          network_card_index          = 0
          security_groups = [
            aws_security_group.main["${local.prefix}-efa"].id,
            aws_security_group.main["${local.prefix}-worker"].id
          ]
        },
        {
          associate_public_ip_address = false
          delete_on_termination       = true
          device_index                = 1
          interface_type              = "efa-only"
          network_card_index          = 0
          security_groups = [
            aws_security_group.main["${local.prefix}-efa"].id,
            aws_security_group.main["${local.prefix}-worker"].id
          ]
        }
      ] :
      local.gpu_family[ng.name] == "gb200" ? [
        for i in [0, 1, 5, 9, 13] : {
          associate_public_ip_address = false
          delete_on_termination       = true
          device_index                = 0
          interface_type              = i == 0 ? "interface" : "efa-only"
          network_card_index          = i
          security_groups = [
            aws_security_group.main["${local.prefix}-efa"].id,
            aws_security_group.main["${local.prefix}-worker"].id
          ]
        }
      ] :
      length(data.aws_ec2_instance_type.worker[ng.name].gpus) > 0 ? [
        for i in range(data.aws_ec2_instance_type.worker[ng.name].maximum_network_cards) : {
          associate_public_ip_address = false
          delete_on_termination       = true
          device_index                = i == 0 ? 0 : 1
          interface_type              = i == 0 ? "efa" : "efa-only"
          network_card_index          = i
          security_groups = [
            aws_security_group.main["${local.prefix}-efa"].id,
            aws_security_group.main["${local.prefix}-worker"].id
          ]
        }
      ] : []
    )
  }

  # #16: Compute effective image ID using for_each AMI data source
  node_group_image_ids = {
    for ng in local.worker_node_groups :
    ng.name => (
      try(ng.imageId, null) != null ? ng.imageId :
      data.aws_ami.ubuntu_eks[try(ng.architecture, "x86_64")].id
    )
  }
}

# SSH Key Pair (optional - only created if sshPublicKey is provided)
resource "aws_key_pair" "main" {
  count = try(local.config.compute.eks.sshPublicKey, null) != null ? 1 : 0

  key_name   = "${local.prefix}-key"
  public_key = local.config.compute.eks.sshPublicKey
}

# Launch Templates for Node Groups
resource "aws_launch_template" "node_groups" {
  for_each = { for i, group in local.worker_node_groups : "${local.prefix}-${group.name}" => group }

  name                   = each.key
  image_id               = local.node_group_image_ids[each.value.name]
  instance_type          = each.value.instanceType
  update_default_version = true
  key_name               = length(aws_key_pair.main) > 0 ? aws_key_pair.main[0].key_name : null

  # Only set vpc_security_group_ids if no network interfaces are specified
  vpc_security_group_ids = length(local.efa_network_interfaces[each.value.name]) > 0 ? null : [
    aws_security_group.main["${local.prefix}-efa"].id,
    aws_security_group.main["${local.prefix}-worker"].id
  ]

  iam_instance_profile {
    arn = aws_iam_instance_profile.worker_nodes.arn
  }

  monitoring {
    enabled = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # Enforces IMDSv2
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = try(each.value.blockDevice.mount, local.block_volume_mount_default)
    ebs {
      volume_size = try(each.value.blockDevice.size, local.block_volume_size_default)
      volume_type = try(each.value.blockDevice.type, local.block_volume_type_default)
      encrypted   = true
    }
  }

  # EFA network interfaces for supported instance types
  # EFA instances must be in the same subnet, so we use the first subnet of the appropriate type
  dynamic "network_interfaces" {
    for_each = local.efa_network_interfaces[each.value.name]
    content {
      associate_public_ip_address = network_interfaces.value.associate_public_ip_address
      delete_on_termination       = network_interfaces.value.delete_on_termination
      device_index                = network_interfaces.value.device_index
      interface_type              = network_interfaces.value.interface_type
      network_card_index          = network_interfaces.value.network_card_index
      security_groups             = network_interfaces.value.security_groups
      subnet_id                   = local.subnet_ids_by_type[each.value.subnet][0]
    }
  }

  # Capacity Reservation options
  # Supports three target formats:
  #   - Direct capacity reservation ID: cr-0cbe491320188dfa6
  #   - Full resource group ARN: arn:aws:resource-groups:us-west-2:123456789:group/my-group
  #   - Resource group name only: my-group (auto-constructs full ARN)
  dynamic "capacity_reservation_specification" {
    for_each = try(each.value.capacity.reservation.preference, null) != null ? [1] : []
    content {
      capacity_reservation_preference = each.value.capacity.reservation.preference
      dynamic "capacity_reservation_target" {
        for_each = try(each.value.capacity.reservation.target, null) != null ? [1] : []
        content {
          capacity_reservation_id = startswith(each.value.capacity.reservation.target, "cr-") ? each.value.capacity.reservation.target : null
          capacity_reservation_resource_group_arn = (
            startswith(each.value.capacity.reservation.target, "arn:") ? each.value.capacity.reservation.target :
            startswith(each.value.capacity.reservation.target, "cr-") ? null :
            "arn:aws:resource-groups:${local.region}:${data.aws_caller_identity.current.account_id}:group/${each.value.capacity.reservation.target}"
          )
        }
      }
    }
  }

  # Instance market options (spot, capacity-block)
  # Can be used together with capacity_reservation_specification for capacity blocks
  dynamic "instance_market_options" {
    for_each = try(each.value.capacity.reservation.marketType, null) != null ? [1] : []
    content {
      market_type = each.value.capacity.reservation.marketType
    }
  }

  # User data script to bootstrap the EKS worker nodes
  user_data = base64encode(<<-EOF
      #!/bin/bash
      set -o xtrace
      export SERVICE_IPV4_CIDR=${aws_eks_cluster.main.kubernetes_network_config[0].service_ipv4_cidr}

      # Use known values from Terraform instead of dynamic lookup
      /usr/local/bin/setup-local-disks raid0 || echo "No local disks found"

      /etc/eks/bootstrap.sh ${aws_eks_cluster.main.name} \
        --b64-cluster-ca ${aws_eks_cluster.main.certificate_authority[0].data} \
        --apiserver-endpoint ${aws_eks_cluster.main.endpoint} \
        --kubelet-extra-args "\
          --node-labels=${local.node_group_labels[each.value.name]} \
          --register-with-taints=${local.node_group_taints[each.value.name]} \
        " \
        --ip-family ipv4
  EOF
  )

  # default_tags don't propagate into launch template tag_specifications
  tag_specifications {
    resource_type = "instance"
    tags = merge(local.effective_tags, {
      Name = each.key
      Role = each.value.type
    })
  }

  tags = merge(local.effective_tags, {
    Name = each.key
  })
}

# Autoscaling Groups for Node Groups
resource "aws_autoscaling_group" "node_groups" {
  for_each = { for i, group in local.worker_node_groups : "${local.prefix}-${group.name}" => group }

  name                = each.key
  vpc_zone_identifier = local.subnet_ids_by_type[each.value.subnet]

  desired_capacity = each.value.capacity.desired
  min_size         = try(each.value.capacity.min, each.value.capacity.desired)
  max_size         = try(each.value.capacity.max, each.value.capacity.desired)

  # Health check configuration
  health_check_type         = "EC2"
  health_check_grace_period = local.asg_health_check_grace_period
  wait_for_capacity_timeout = local.asg_capacity_timeout

  # Termination policies
  termination_policies = [
    "OldestLaunchTemplate",
    "OldestInstance"
  ]

  # Instance refresh for zero-downtime updates
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = local.asg_min_healthy_percentage
      instance_warmup        = local.asg_instance_warmup
      checkpoint_percentages = local.asg_checkpoint_percentages
    }
  }

  # CloudWatch metrics collection
  enabled_metrics = [
    "GroupDesiredCapacity",
    "GroupInServiceInstances",
    "GroupMaxSize",
    "GroupMinSize",
    "GroupPendingInstances",
    "GroupStandbyInstances",
    "GroupTerminatingInstances",
    "GroupTotalInstances"
  ]
  metrics_granularity = local.metrics_granularity

  launch_template {
    id      = aws_launch_template.node_groups[each.key].id
    version = "$Latest"
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity] # Allow cluster autoscaler to manage
  }

  timeouts {
    delete = local.asg_delete_timeout
  }

  tag {
    key                 = "kubernetes.io/cluster/${aws_eks_cluster.main.name}"
    value               = "owned"
    propagate_at_launch = true
  }

  tag {
    key                 = "k8s.io/cluster/${aws_eks_cluster.main.name}"
    value               = "owned"
    propagate_at_launch = true
  }

  tag {
    key                 = "Name"
    value               = each.key
    propagate_at_launch = true
  }

  # Cluster Autoscaler tags
  tag {
    key                 = "k8s.io/cluster-autoscaler/${aws_eks_cluster.main.name}"
    value               = "owned"
    propagate_at_launch = false
  }

  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = false
  }

  # ASG `tag {}` blocks do not inherit provider default_tags — set explicitly
  # so tools/delete-eks can discover ASGs via tag filters.
  tag {
    key                 = "Cluster"
    value               = local.prefix
    propagate_at_launch = true
  }

  tag {
    key                 = "ManagedBy"
    value               = "cluster-toolkit"
    propagate_at_launch = true
  }
}

# Launch template for system nodes — sets IMDS hop limit to 2 so containerized
# workloads (e.g. EBS CSI driver) can reach the instance metadata endpoint.
resource "aws_launch_template" "system" {
  name                   = "${local.prefix}-system"
  update_default_version = true

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # Enforces IMDSv2
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = try(local.config.compute.eks.nodeGroups.system.blockDevice.size, local.block_volume_size_default)
      volume_type = try(local.config.compute.eks.nodeGroups.system.blockDevice.type, local.block_volume_type_default)
      encrypted   = true
    }
  }

  tags = merge(local.effective_tags, {
    Name = "${local.prefix}-system"
  })
}

# EKS Managed Node Group for System Nodes
# Uses AL2023 defaults — launch template only overrides IMDS metadata options
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.prefix}-system"
  node_role_arn   = aws_iam_role.system_nodes.arn
  subnet_ids      = local.system_subnet_ids

  instance_types = [local.config.compute.eks.nodeGroups.system.instanceType]
  ami_type       = "AL2023_x86_64_STANDARD"

  launch_template {
    id      = aws_launch_template.system.id
    version = aws_launch_template.system.latest_version
  }

  scaling_config {
    desired_size = local.config.compute.eks.nodeGroups.system.capacity.desired
    min_size     = try(local.config.compute.eks.nodeGroups.system.capacity.min, local.config.compute.eks.nodeGroups.system.capacity.desired)
    max_size     = try(local.config.compute.eks.nodeGroups.system.capacity.max, local.config.compute.eks.nodeGroups.system.capacity.desired)
  }

  update_config {
    max_unavailable_percentage = 10
  }

  taint {
    key    = "dedicated"
    value  = "system-workload"
    effect = "NO_SCHEDULE"
  }

  taint {
    key    = "dedicated"
    value  = "system-workload"
    effect = "NO_EXECUTE"
  }

  # Additional taints from config, appended to the default dedicated taints
  dynamic "taint" {
    for_each = try(local.config.compute.eks.nodeGroups.system.taints, [])
    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = local.taint_effect_api[taint.value.effect]
    }
  }

  labels = try(local.config.compute.eks.nodeGroups.system.labels, {})

  tags = merge(local.effective_tags, {
    Name = "${local.prefix}-system"
  })

  # AWS requires IAM policies attached before node group creation
  depends_on = [
    aws_iam_role_policy_attachment.system_nodes_policy,
    aws_iam_role_policy_attachment.system_nodes_cni_policy,
    aws_iam_role_policy_attachment.system_nodes_container_registry_readonly,
    aws_iam_role_policy_attachment.system_nodes_ssm_managed_instance_core,
    aws_iam_role_policy_attachment.system_nodes_service_role_ebs_csi_driver_policy,
  ]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}
