// =====================================================================================
// Node Pools
// =====================================================================================

locals {
}

// All node pools
resource "google_container_node_pool" "pools" {
  for_each = { for np in local.all_node_pools : np.name => np }

  name     = "${local.prefix}-${each.key}"
  location = local.region
  cluster  = google_container_cluster.main.id
  project  = local.project

  # Version management
  version = try(each.value.version, null)

  # Initial node count (will be managed by autoscaling)
  initial_node_count = try(each.value.autoscaling.minNodes, 1)

  # Autoscaling configuration
  dynamic "autoscaling" {
    for_each = try(each.value.autoscaling.enabled, true) ? [1] : []
    content {
      min_node_count       = try(each.value.autoscaling.minNodes, 1)
      max_node_count       = try(each.value.autoscaling.maxNodes, 3)
      location_policy      = try(each.value.autoscaling.locationPolicy, "BALANCED")
      total_min_node_count = try(each.value.autoscaling.totalMinNodes, null)
      total_max_node_count = try(each.value.autoscaling.totalMaxNodes, null)
    }
  }

  # Node configuration
  node_config {
    machine_type = each.value.machineType
    image_type   = try(each.value.imageType, "COS_CONTAINERD")

    disk_type    = try(each.value.diskType, "pd-standard")
    disk_size_gb = try(each.value.diskSizeGb, 100)

    # Service account
    service_account = each.value.type == "system" ? google_service_account.system_nodes.email : google_service_account.worker_nodes.email

    # OAuth scopes
    oauth_scopes = try(each.value.nodeConfig.oauthScopes, [
      "https://www.googleapis.com/auth/cloud-platform"
    ])

    # Preemptible/Spot instances
    preemptible = try(each.value.nodeConfig.preemptible, false)
    spot        = try(each.value.nodeConfig.spot, false)

    # Capacity reservation
    dynamic "reservation_affinity" {
      for_each = try(each.value.nodeConfig.capacityReservations, [])
      content {
        consume_reservation_type = "SPECIFIC_RESERVATION"
        key                      = "compute.googleapis.com/reservation-name"
        values                   = each.value
      }
    }

    # Labels
    labels = merge(
      try(each.value.nodeConfig.labels, {}),
      {
        "gke-cluster" = local.config.cluster.name
        "node-pool"   = each.key
        "node-type"   = each.value.type
      }
    )

    # Tags
    tags = concat(
      ["gke-${local.prefix}"],
      try(each.value.nodeConfig.tags, [])
    )

    # Taints
    dynamic "taint" {
      for_each = try(each.value.nodeConfig.taints, [])
      content {
        key    = taint.value.key
        value  = taint.value.value
        effect = taint.value.effect
      }
    }

    # GPU configuration
    dynamic "guest_accelerator" {
      for_each = try(each.value.guestAccelerator, null) != null ? [each.value.guestAccelerator] : []
      content {
        type  = guest_accelerator.value.type
        count = guest_accelerator.value.count

        dynamic "gpu_driver_installation_config" {
          for_each = try(guest_accelerator.value.gpuDriverInstallation, null) != null ? [1] : []
          content {
            gpu_driver_version = try(guest_accelerator.value.gpuDriverInstallation.gpuDriverVersion, "DEFAULT")
          }
        }

        dynamic "gpu_sharing_config" {
          for_each = try(guest_accelerator.value.gpuSharingConfig, null) != null ? [1] : []
          content {
            gpu_sharing_strategy       = try(guest_accelerator.value.gpuSharingConfig.strategy, "TIME_SHARING")
            max_shared_clients_per_gpu = try(guest_accelerator.value.gpuSharingConfig.maxSharedClients, 2)
          }
        }
      }
    }

    # Shielded instance configuration
    dynamic "shielded_instance_config" {
      for_each = try(each.value.nodeConfig.shieldedInstanceConfig, null) != null ? [1] : []
      content {
        enable_secure_boot          = try(each.value.nodeConfig.shieldedInstanceConfig.enableSecureBoot, true)
        enable_integrity_monitoring = try(each.value.nodeConfig.shieldedInstanceConfig.enableIntegrityMonitoring, true)
      }
    }

    # Workload metadata configuration
    dynamic "workload_metadata_config" {
      for_each = local.workload_identity_enabled ? [1] : []
      content {
        mode = "GKE_METADATA"
      }
    }

    # Metadata
    metadata = merge(
      {
        "disable-legacy-endpoints" = "true"
      },
      try(each.value.nodeConfig.metadata, {})
    )
  }

  # Management configuration
  management {
    auto_repair  = try(each.value.autoRepair, true)
    auto_upgrade = try(each.value.autoUpgrade, true)
  }

  # Upgrade settings
  upgrade_settings {
    max_surge       = try(each.value.upgradeSettings.maxSurge, 1)
    max_unavailable = try(each.value.upgradeSettings.maxUnavailable, 0)
    strategy        = try(each.value.upgradeSettings.strategy, "SURGE")

    dynamic "blue_green_settings" {
      for_each = try(each.value.upgradeSettings.strategy, "SURGE") == "BLUE_GREEN" ? [1] : []
      content {
        node_pool_soak_duration = try(each.value.upgradeSettings.blueGreen.nodePoolSoakDuration, "0s")

        standard_rollout_policy {
          batch_percentage    = try(each.value.upgradeSettings.blueGreen.batchPercentage, null)
          batch_node_count    = try(each.value.upgradeSettings.blueGreen.batchNodeCount, null)
          batch_soak_duration = try(each.value.upgradeSettings.blueGreen.batchSoakDuration, "0s")
        }
      }
    }
  }

  # Network configuration
  network_config {
    create_pod_range     = false
    enable_private_nodes = local.private_cluster_enabled
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }

  lifecycle {
    ignore_changes = [
      initial_node_count,
      node_config[0].labels,
      node_config[0].taint,
    ]
  }

  depends_on = [
    google_container_cluster.main,
    google_service_account.system_nodes,
    google_service_account.worker_nodes,
  ]
}
