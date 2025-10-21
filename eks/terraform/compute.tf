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

  # Flatten nodeGroups structure: system object + workers array
  all_node_groups = concat(
    # Add system node group with name and type
    [
      merge(
        local.config.compute.nodeGroups.system,
        {
          name   = "system"
          type   = "system"
          subnet = "system"
        }
      )
    ],
    # Add workers array with type attribute
    [
      for worker in local.config.compute.nodeGroups.workers :
      merge(
        worker,
        {
          type   = "worker"
          subnet = "worker"
        }
      )
    ]
  )

  # Prepare node group labels and taints for use in user data scripts
  node_group_labels = {
    for ng in local.all_node_groups :
    ng.name => join(
      ",",
      [for k, v in ng.labels : "${k}=${v}"]
    )
  }
}

# SSH Key Pair
resource "aws_key_pair" "main" {
  key_name   = "${local.prefix}-key"
  public_key = local.config.compute.sshPublicKey
}

# Launch Templates for Node Groups
resource "aws_launch_template" "node_groups" {
  for_each = { for i, group in local.all_node_groups : "${local.prefix}-${group.name}" => group }

  name                   = each.key
  image_id               = each.value.imageId
  instance_type          = each.value.instanceType
  update_default_version = true
  key_name               = aws_key_pair.main.key_name

  # Only set vpc_security_group_ids if no network interfaces are specified
  vpc_security_group_ids = contains(keys(local.efa_network_interfaces), try(each.value.accelerator, "na")) ? null : [
    aws_security_group.main["${local.prefix}-efa"].id,
    aws_security_group.main["${local.prefix}-worker"].id
  ]

  iam_instance_profile {
    arn = each.value.type == "system" ? aws_iam_instance_profile.system_nodes.arn : aws_iam_instance_profile.worker_nodes.arn
  }

  monitoring {
    enabled = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  block_device_mappings {
    device_name = try(each.value.blockDevice.mount, local.blockVolumeMountDefault)
    ebs {
      volume_size = try(each.value.blockDevice.size, local.blockVolumeSizeDefault)
      volume_type = try(each.value.blockDevice.type, local.blockVolumeTypeDefault)
      encrypted   = true
    }
  }

  # EFA network interfaces for supported instance types
  dynamic "network_interfaces" {
    for_each = contains(keys(local.efa_network_interfaces), try(each.value.accelerator, "na")) ? local.efa_network_interfaces[each.value.accelerator] : []
    content {
      associate_public_ip_address = network_interfaces.value.associate_public_ip_address
      delete_on_termination       = network_interfaces.value.delete_on_termination
      device_index                = network_interfaces.value.device_index
      interface_type              = network_interfaces.value.interface_type
      network_card_index          = network_interfaces.value.network_card_index
      security_groups             = network_interfaces.value.security_groups
      subnet_id                   = aws_subnet.main["${local.prefix}-${group.name}-subnet"].id
    }
  }

  # Capacity Reservation and Spot options
  dynamic "capacity_reservation_specification" {
    for_each = try(each.value.capacity.reservation.preference, null) != null && try(each.value.capacity.reservation.marketType, null) == null ? [1] : []
    content {
      capacity_reservation_preference = each.value.capacity.reservation.preference
      dynamic "capacity_reservation_target" {
        for_each = try(each.value.capacity.reservation.resourceGroupArn, null) != null ? [1] : []
        content {
          capacity_reservation_resource_group_arn = "arn:aws:resource-groups:${local.config.deployment.region}:${data.aws_caller_identity.current.account_id}:group/${each.value.capacity.reservation.resourceGroupArn}"
        }
      }
    }
  }

  dynamic "instance_market_options" {
    for_each = try(each.value.capacity.reservation.marketType, null) != null && try(each.value.capacity.reservation.preference, null) != "capacity-reservations-only" ? [1] : []
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

  tag_specifications {
    resource_type = "instance"
    tags = merge(local.config.deployment.tags, {
      Name = each.key
      Role = each.value.type
    })
  }

  tags = merge(local.config.deployment.tags, {
    Name = each.key
  })
}

# Autoscaling Groups for Node Groups
resource "aws_autoscaling_group" "node_groups" {
  for_each = { for i, group in local.all_node_groups : "${local.prefix}-${group.name}" => group }

  name                = each.key
  vpc_zone_identifier = local.subnet_ids_by_type[each.value.subnet]

  desired_capacity = each.value.capacity.desired
  min_size         = try(each.value.capacity.min, each.value.capacity.desired)
  max_size         = try(each.value.capacity.max, each.value.capacity.desired)

  # Health check configuration
  health_check_type         = "EC2"
  health_check_grace_period = local.asgHealthCheckGracePeriod
  wait_for_capacity_timeout = local.asgCapacityTimeout

  # Termination policies
  termination_policies = [
    "OldestLaunchTemplate",
    "OldestInstance"
  ]

  # Instance refresh for zero-downtime updates
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = local.asgMinHealthyPercentage
      instance_warmup        = local.asgInstanceWarmup
      checkpoint_percentages = local.asgCheckpointPercentages
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
  metrics_granularity = local.metricsGranularity

  launch_template {
    id      = aws_launch_template.node_groups[each.key].id
    version = "$Latest"
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity] # Allow cluster autoscaler to manage
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
