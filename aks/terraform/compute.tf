// Additional (user) node pools
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  for_each = local.user_node_pools

  name                  = each.key
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = each.value.vmSize
  orchestrator_version  = local.aks_version
  zones                 = try(each.value.availabilityZones, ["1", "2", "3"])
  mode                  = "User"

  # Scaling configuration
  auto_scaling_enabled = try(each.value.autoscaling.enabled, true)
  min_count            = try(each.value.autoscaling.enabled, true) ? try(each.value.autoscaling.minSize, 0) : null
  max_count            = try(each.value.autoscaling.enabled, true) ? try(each.value.autoscaling.maxSize, 10) : null
  node_count           = try(each.value.autoscaling.enabled, true) ? null : try(each.value.size, 3)

  # Node configuration
  max_pods        = try(each.value.maxPods, 110)
  os_disk_size_gb = try(each.value.osDiskSizeGb, 128)
  os_disk_type    = try(each.value.osDiskType, "Managed")
  os_type         = try(each.value.osType, "Linux")
  os_sku          = try(each.value.osSku, "Ubuntu")

  # Network configuration
  vnet_subnet_id = azurerm_subnet.worker.id
  pod_subnet_id  = local.network_plugin == "azure" && try(local.config.network.podSubnetCidr, null) != null ? azurerm_subnet.pods[0].id : null

  # Node labels and taints
  node_labels = merge(
    try(each.value.labels, {}),
    {
      "nodepool" = each.key
    }
  )

  node_taints = try(each.value.taints, null) != null ? ["workload=${each.key}:${try(each.value.taintsEffect, "NoSchedule")}"] : null

  # Upgrade settings
  upgrade_settings {
    max_surge = try(each.value.maxSurge, "10%")
  }

  # Spot instances configuration
  priority        = try(each.value.spot, false) ? "Spot" : "Regular"
  eviction_policy = try(each.value.spot, false) ? try(each.value.evictionPolicy, "Delete") : null
  spot_max_price  = try(each.value.spot, false) ? try(each.value.spotMaxPrice, -1) : null

  # Enable host encryption if specified
  host_encryption_enabled = try(each.value.enableHostEncryption, false)

  # Enable node public IP if specified
  node_public_ip_enabled = try(each.value.enableNodePublicIp, false)

  # Kubelet configuration
  dynamic "kubelet_config" {
    for_each = try(each.value.kubeletConfig, null) != null ? [1] : []
    content {
      cpu_manager_policy        = try(each.value.kubeletConfig.cpuManagerPolicy, "none")
      cpu_cfs_quota_enabled     = try(each.value.kubeletConfig.cpuCfsQuotaEnabled, true)
      cpu_cfs_quota_period      = try(each.value.kubeletConfig.cpuCfsQuotaPeriod, "100ms")
      image_gc_high_threshold   = try(each.value.kubeletConfig.imageGcHighThreshold, 85)
      image_gc_low_threshold    = try(each.value.kubeletConfig.imageGcLowThreshold, 80)
      topology_manager_policy   = try(each.value.kubeletConfig.topologyManagerPolicy, "none")
      allowed_unsafe_sysctls    = try(each.value.kubeletConfig.allowedUnsafeSysctls, [])
      container_log_max_size_mb = try(each.value.kubeletConfig.containerLogMaxSizeMb, 50)
      container_log_max_line    = try(each.value.kubeletConfig.containerLogMaxLine, 50000)
      pod_max_pid               = try(each.value.kubeletConfig.podMaxPid, -1)
    }
  }

  # Linux OS configuration
  dynamic "linux_os_config" {
    for_each = try(each.value.linuxOsConfig, null) != null && try(each.value.osType, "Linux") == "Linux" ? [1] : []
    content {
      swap_file_size_mb = try(each.value.linuxOsConfig.swapFileSizeMb, 0)

      dynamic "sysctl_config" {
        for_each = try(each.value.linuxOsConfig.sysctlConfig, null) != null ? [1] : []
        content {
          fs_aio_max_nr                      = try(each.value.linuxOsConfig.sysctlConfig.fsAioMaxNr, null)
          fs_file_max                        = try(each.value.linuxOsConfig.sysctlConfig.fsFileMax, null)
          fs_inotify_max_user_watches        = try(each.value.linuxOsConfig.sysctlConfig.fsInotifyMaxUserWatches, null)
          fs_nr_open                         = try(each.value.linuxOsConfig.sysctlConfig.fsNrOpen, null)
          kernel_threads_max                 = try(each.value.linuxOsConfig.sysctlConfig.kernelThreadsMax, null)
          net_core_netdev_max_backlog        = try(each.value.linuxOsConfig.sysctlConfig.netCoreNetdevMaxBacklog, null)
          net_core_optmem_max                = try(each.value.linuxOsConfig.sysctlConfig.netCoreOptmemMax, null)
          net_core_rmem_default              = try(each.value.linuxOsConfig.sysctlConfig.netCoreRmemDefault, null)
          net_core_rmem_max                  = try(each.value.linuxOsConfig.sysctlConfig.netCoreRmemMax, null)
          net_core_somaxconn                 = try(each.value.linuxOsConfig.sysctlConfig.netCoreSomaxconn, null)
          net_core_wmem_default              = try(each.value.linuxOsConfig.sysctlConfig.netCoreWmemDefault, null)
          net_core_wmem_max                  = try(each.value.linuxOsConfig.sysctlConfig.netCoreWmemMax, null)
          net_ipv4_ip_local_port_range_min   = try(each.value.linuxOsConfig.sysctlConfig.netIpv4IpLocalPortRangeMin, null)
          net_ipv4_ip_local_port_range_max   = try(each.value.linuxOsConfig.sysctlConfig.netIpv4IpLocalPortRangeMax, null)
          net_ipv4_neigh_default_gc_thresh1  = try(each.value.linuxOsConfig.sysctlConfig.netIpv4NeighDefaultGcThresh1, null)
          net_ipv4_neigh_default_gc_thresh2  = try(each.value.linuxOsConfig.sysctlConfig.netIpv4NeighDefaultGcThresh2, null)
          net_ipv4_neigh_default_gc_thresh3  = try(each.value.linuxOsConfig.sysctlConfig.netIpv4NeighDefaultGcThresh3, null)
          net_ipv4_tcp_fin_timeout           = try(each.value.linuxOsConfig.sysctlConfig.netIpv4TcpFinTimeout, null)
          net_ipv4_tcp_keepalive_intvl       = try(each.value.linuxOsConfig.sysctlConfig.netIpv4TcpKeepaliveIntvl, null)
          net_ipv4_tcp_keepalive_probes      = try(each.value.linuxOsConfig.sysctlConfig.netIpv4TcpKeepaliveProbes, null)
          net_ipv4_tcp_keepalive_time        = try(each.value.linuxOsConfig.sysctlConfig.netIpv4TcpKeepaliveTime, null)
          net_ipv4_tcp_max_syn_backlog       = try(each.value.linuxOsConfig.sysctlConfig.netIpv4TcpMaxSynBacklog, null)
          net_ipv4_tcp_max_tw_buckets        = try(each.value.linuxOsConfig.sysctlConfig.netIpv4TcpMaxTwBuckets, null)
          net_ipv4_tcp_tw_reuse              = try(each.value.linuxOsConfig.sysctlConfig.netIpv4TcpTwReuse, null)
          net_netfilter_nf_conntrack_buckets = try(each.value.linuxOsConfig.sysctlConfig.netNetfilterNfConntrackBuckets, null)
          net_netfilter_nf_conntrack_max     = try(each.value.linuxOsConfig.sysctlConfig.netNetfilterNfConntrackMax, null)
          vm_max_map_count                   = try(each.value.linuxOsConfig.sysctlConfig.vmMaxMapCount, null)
          vm_swappiness                      = try(each.value.linuxOsConfig.sysctlConfig.vmSwappiness, null)
          vm_vfs_cache_pressure              = try(each.value.linuxOsConfig.sysctlConfig.vmVfsCachePressure, null)
        }
      }

      transparent_huge_page_enabled = try(each.value.linuxOsConfig.transparentHugePageEnabled, "always")
      transparent_huge_page_defrag  = try(each.value.linuxOsConfig.transparentHugePageDefrag, "always")
    }
  }

  # Windows configuration
  dynamic "windows_profile" {
    for_each = try(each.value.osType, "Linux") == "Windows" ? [1] : []
    content {
      outbound_nat_enabled = try(each.value.windowsProfile.outboundNatEnabled, true)
    }
  }

  tags = merge(
    local.tags,
    {
      "nodepool" = each.key
    }
  )

  lifecycle {
    ignore_changes = [
      node_count,
      orchestrator_version
    ]
  }
}
