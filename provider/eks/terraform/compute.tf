locals {
  # AWS recommended spec for P6e and P6i GB200 instances
  # NCI0 as ENA (EFA) for 100Gbps for N/S
  # NCI1, 5, 9, & 13 as EFA-only for 400Gbps for E/W for a total of 1600G E/W
  efa_network_interfaces = {
    gb200 = [
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
    ]
    h100 = [
      for i in range(4) : {
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
    ]
  }

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

  # Map instance type prefix to EFA accelerator type
  # p5 = H100, p6e/p6i = GB200
  instance_type_accelerators = {
    "p5"  = "h100"
    "p6e" = "gb200"
    "p6i" = "gb200"
  }

  # Effective accelerator per worker: explicit config wins, otherwise derive from instance type prefix
  effective_accelerators = {
    for ng in local.worker_node_groups :
    ng.name => coalesce(
      try(ng.accelerator, null),
      try(local.instance_type_accelerators[split(".", ng.instanceType)[0]], null),
      "na"
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
  vpc_security_group_ids = contains(keys(local.efa_network_interfaces), local.effective_accelerators[each.value.name]) ? null : [
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
    http_tokens                 = "required"
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
    for_each = contains(keys(local.efa_network_interfaces), local.effective_accelerators[each.value.name]) ? local.efa_network_interfaces[local.effective_accelerators[each.value.name]] : []
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
          --register-with-taints=${local.node_group_taints[each.value.type]} \
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
}

# EKS Managed Node Group for System Nodes
# Uses AL2023 defaults — no custom AMI, launch template, or bootstrap script needed
resource "aws_eks_node_group" "system" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "${local.prefix}-system"
  node_role_arn   = aws_iam_role.system_nodes.arn
  subnet_ids      = local.system_subnet_ids

  instance_types = [local.config.compute.eks.nodeGroups.system.instanceType]
  ami_type       = "AL2023_x86_64_STANDARD"
  disk_size      = try(local.config.compute.eks.nodeGroups.system.blockDevice.size, local.block_volume_size_default)

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
