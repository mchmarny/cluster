// =====================================================================================
// Worker Node Pools
// =====================================================================================

// User-mode node pools for workloads. The system pool is the cluster's
// default_node_pool (see cluster.tf); workers are added here via for_each.
resource "azurerm_kubernetes_cluster_node_pool" "workers" {
  for_each = local.worker_pools

  name                  = each.value.name
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = each.value.vm_size
  orchestrator_version  = local.kubernetes_version
  mode                  = "User"
  os_disk_type          = each.value.os_disk_type
  os_disk_size_gb       = each.value.os_disk_size
  max_pods              = each.value.max_pods
  vnet_subnet_id        = azurerm_subnet.worker.id
  zones                 = local.zones
  tags                  = local.tags

  auto_scaling_enabled = each.value.auto_scaling
  min_count            = each.value.auto_scaling ? each.value.min_nodes : null
  max_count            = each.value.auto_scaling ? each.value.max_nodes : null
  node_count           = each.value.auto_scaling ? null : each.value.node_count

  // Must be set explicitly for GPU pools: Azure defaults to "Install" and
  // records it in state, and an unset value re-plans as null — a ForceNew
  // diff that replaces the pool on every apply. Driver install is opt-in
  // via gpuDriverInstall; "None" assumes an in-cluster driver (GPU Operator).
  gpu_driver = each.value.is_gpu ? (each.value.gpu_driver_install ? "Install" : "None") : null

  node_labels = each.value.labels

  // Taints from config, plus the NVIDIA taint for GPU pools so only GPU
  // workloads schedule there. Driver installation is controlled by
  // gpu_driver below (assumes H100 SKU for gpuType pools).
  node_taints = concat(
    [for t in each.value.config_taints : "${t.key}=${t.value}:${t.effect}"],
    each.value.is_gpu ? ["nvidia.com/gpu=present:NoSchedule"] : []
  )

  upgrade_settings {
    max_surge = "10%"
  }

  lifecycle {
    ignore_changes = [
      // Cluster autoscaler manages the running node count.
      node_count,
    ]
  }

  timeouts {
    // GPU pools (ND-series, e.g. 2x Standard_ND96isr_H100_v5) routinely
    // need more than 30m to allocate in shared-capacity regions; a 30m
    // create cap kills terraform with "polling after CreateOrUpdate:
    // context deadline exceeded" while Azure finishes the pool
    // out-of-band (observed: NVIDIA/aicr UAT run 29116054044, westus).
    // Update matches create (node-image upgrades walk the same pool);
    // delete stays tighter — pool deletion is not capacity-bound.
    create = "60m"
    update = "60m"
    delete = "30m"
  }
}
