// trivy:ignore:AVD-AZU-0041 API access restrictions configured via api_server_access_profile and private_cluster settings
// trivy:ignore:AVD-AZU-0042 RBAC is enabled via azure_active_directory_role_based_access_control block
resource "azurerm_kubernetes_cluster" "main" {
  name                             = local.cluster_name
  location                         = local.location
  resource_group_name              = local.resource_group_name
  dns_prefix                       = local.prefix
  kubernetes_version               = local.aks_version
  sku_tier                         = try(local.config.cluster.skuTier, "Standard")
  private_cluster_enabled          = local.private_cluster_enabled
  private_dns_zone_id              = local.private_dns_zone_id
  local_account_disabled           = local.local_account_disabled
  workload_identity_enabled        = local.workload_identity_enabled
  oidc_issuer_enabled              = local.oidc_issuer_enabled
  azure_policy_enabled             = local.azure_policy_enabled
  http_application_routing_enabled = local.http_application_routing_enabled
  automatic_upgrade_channel        = try(local.config.cluster.automaticUpgrade, "stable")
  node_resource_group              = "${local.resource_group_name}-${local.cluster_name}-nodes"

  tags = local.tags

  # Default system node pool
  default_node_pool {
    name                         = local.system_node_pool_key
    vm_size                      = local.system_node_pool.vmSize
    orchestrator_version         = local.aks_version
    zones                        = try(local.system_node_pool.availabilityZones, ["1", "2", "3"])
    auto_scaling_enabled         = try(local.system_node_pool.autoscaling.enabled, true)
    min_count                    = try(local.system_node_pool.autoscaling.enabled, true) ? try(local.system_node_pool.autoscaling.minSize, 1) : null
    max_count                    = try(local.system_node_pool.autoscaling.enabled, true) ? try(local.system_node_pool.autoscaling.maxSize, 3) : null
    node_count                   = try(local.system_node_pool.autoscaling.enabled, true) ? null : try(local.system_node_pool.size, 2)
    max_pods                     = try(local.system_node_pool.maxPods, 110)
    os_disk_size_gb              = try(local.system_node_pool.osDiskSizeGb, 128)
    os_disk_type                 = try(local.system_node_pool.osDiskType, "Managed")
    vnet_subnet_id               = azurerm_subnet.system.id
    pod_subnet_id                = local.network_plugin == "azure" && try(local.config.network.podSubnetCidr, null) != null ? azurerm_subnet.pods[0].id : null
    node_labels                  = try(local.system_node_pool.labels, {})
    only_critical_addons_enabled = try(local.system_node_pool.taintsEffect, null) == "NoSchedule"

    upgrade_settings {
      max_surge = try(local.system_node_pool.maxSurge, "10%")
    }

    dynamic "node_network_profile" {
      for_each = try(local.config.security.allowedApplicationSecurityGroupIds, null) != null ? [1] : []
      content {
        allowed_host_ports {
          port_start = 22
          port_end   = 22
          protocol   = "TCP"
        }
      }
    }
  }

  # Network profile
  network_profile {
    network_plugin    = local.network_plugin
    network_mode      = local.network_mode
    network_policy    = local.network_policy
    dns_service_ip    = local.dns_service_ip
    service_cidr      = local.service_cidr
    pod_cidr          = local.network_plugin == "kubenet" ? local.pod_cidr : null
    outbound_type     = local.outbound_type
    load_balancer_sku = "standard"

    dynamic "load_balancer_profile" {
      for_each = local.outbound_type == "loadBalancer" ? [1] : []
      content {
        managed_outbound_ip_count = try(local.config.network.outboundIpCount, 1)
        idle_timeout_in_minutes   = try(local.config.network.loadBalancerIdleTimeout, 30)
        outbound_ports_allocated  = try(local.config.network.outboundPortsAllocated, 0)
      }
    }
  }

  # Identity
  identity {
    type = "SystemAssigned"
  }

  # API server access profile
  dynamic "api_server_access_profile" {
    for_each = !local.private_cluster_enabled && length(local.api_server_authorized_ranges) > 0 ? [1] : []
    content {
      authorized_ip_ranges = local.api_server_authorized_ranges
    }
  }

  # Azure Active Directory integration
  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = local.rbac_enabled
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  # Key Vault secrets provider addon
  dynamic "key_vault_secrets_provider" {
    for_each = local.azure_keyvault_secrets_provider ? [1] : []
    content {
      secret_rotation_enabled  = try(local.config.cluster.addons.secretRotation, true)
      secret_rotation_interval = try(local.config.cluster.addons.secretRotationInterval, "2m")
    }
  }

  # OMS agent for monitoring
  dynamic "oms_agent" {
    for_each = try(local.config.monitoring.logAnalyticsWorkspaceId, null) != null ? [1] : []
    content {
      log_analytics_workspace_id      = local.config.monitoring.logAnalyticsWorkspaceId
      msi_auth_for_monitoring_enabled = true
    }
  }

  # Microsoft Defender for Containers
  dynamic "microsoft_defender" {
    for_each = local.defender_enabled ? [1] : []
    content {
      log_analytics_workspace_id = local.config.monitoring.logAnalyticsWorkspaceId
    }
  }

  # Automatic upgrade maintenance window
  dynamic "maintenance_window" {
    for_each = try(local.config.cluster.maintenanceWindow, null) != null ? [1] : []
    content {
      dynamic "allowed" {
        for_each = try(local.config.cluster.maintenanceWindow.allowed, [])
        content {
          day   = allowed.value.day
          hours = allowed.value.hours
        }
      }
      dynamic "not_allowed" {
        for_each = try(local.config.cluster.maintenanceWindow.notAllowed, [])
        content {
          start = not_allowed.value.start
          end   = not_allowed.value.end
        }
      }
    }
  }

  # Auto-scaler profile
  dynamic "auto_scaler_profile" {
    for_each = try(local.config.cluster.autoScalerProfile, null) != null ? [1] : []
    content {
      balance_similar_node_groups      = try(local.config.cluster.autoScalerProfile.balanceSimilarNodeGroups, false)
      expander                         = try(local.config.cluster.autoScalerProfile.expander, "random")
      max_graceful_termination_sec     = try(local.config.cluster.autoScalerProfile.maxGracefulTerminationSec, 600)
      max_node_provisioning_time       = try(local.config.cluster.autoScalerProfile.maxNodeProvisioningTime, "15m")
      max_unready_nodes                = try(local.config.cluster.autoScalerProfile.maxUnreadyNodes, 3)
      max_unready_percentage           = try(local.config.cluster.autoScalerProfile.maxUnreadyPercentage, 45)
      new_pod_scale_up_delay           = try(local.config.cluster.autoScalerProfile.newPodScaleUpDelay, "0s")
      scale_down_delay_after_add       = try(local.config.cluster.autoScalerProfile.scaleDownDelayAfterAdd, "10m")
      scale_down_delay_after_delete    = try(local.config.cluster.autoScalerProfile.scaleDownDelayAfterDelete, "10s")
      scale_down_delay_after_failure   = try(local.config.cluster.autoScalerProfile.scaleDownDelayAfterFailure, "3m")
      scan_interval                    = try(local.config.cluster.autoScalerProfile.scanInterval, "10s")
      scale_down_unneeded              = try(local.config.cluster.autoScalerProfile.scaleDownUnneeded, "10m")
      scale_down_unready               = try(local.config.cluster.autoScalerProfile.scaleDownUnready, "20m")
      scale_down_utilization_threshold = try(local.config.cluster.autoScalerProfile.scaleDownUtilizationThreshold, "0.5")
      empty_bulk_delete_max            = try(local.config.cluster.autoScalerProfile.emptyBulkDeleteMax, 10)
      skip_nodes_with_local_storage    = try(local.config.cluster.autoScalerProfile.skipNodesWithLocalStorage, true)
      skip_nodes_with_system_pods      = try(local.config.cluster.autoScalerProfile.skipNodesWithSystemPods, true)
    }
  }

  lifecycle {
    ignore_changes = [
      default_node_pool[0].node_count,
      kubernetes_version
    ]
    prevent_destroy = false
  }
}
