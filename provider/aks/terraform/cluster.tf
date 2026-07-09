// =====================================================================================
// Key Vault + Key for etcd KMS encryption (best-effort, guarded by kms_enabled)
// =====================================================================================
//
// NOTE (live-validate): KMS etcd encryption on AKS is documented with a
// user-assigned identity granted access to the key BEFORE cluster creation.
// This module uses the cluster's SystemAssigned identity and grants it access
// after creation, which can require a post-create reconcile. Purge protection
// is mandatory for KMS keys and forces a soft-delete retention window, so this
// is disabled by default. Verify end-to-end against a live subscription.

resource "azurerm_key_vault" "main" {
  count = local.kms_enabled ? 1 : 0

  name                       = substr("${local.prefix}-kv", 0, 24)
  location                   = azurerm_resource_group.main.location
  resource_group_name        = azurerm_resource_group.main.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  purge_protection_enabled   = true
  soft_delete_retention_days = 7
  tags                       = local.tags

  // Default-deny network ACL: block public access unless explicitly allowed.
  // AKS KMS reaches the vault via the AzureServices bypass; the deployer's
  // egress IP is allowed so Terraform can create/manage the crypto key.
  network_acls {
    default_action = "Deny"
    bypass         = "AzureServices"
    ip_rules       = [trimspace(data.http.egress_ip.response_body)]
  }

  // Deployer needs key management permissions to create the crypto key.
  access_policy {
    tenant_id = data.azurerm_client_config.current.tenant_id
    object_id = data.azurerm_client_config.current.object_id

    key_permissions = [
      "Create",
      "Delete",
      "Get",
      "List",
      "Purge",
      "Recover",
      "Update",
      "GetRotationPolicy",
      "SetRotationPolicy",
    ]
  }
}

// Two key variants selected by kms_prevent_destroy — mirrors the GKE crypto-key
// pattern, because lifecycle.prevent_destroy only accepts a literal.
resource "azurerm_key_vault_key" "etcd" {
  count = (local.kms_enabled && !local.kms_prevent_destroy) ? 1 : 0

  name         = "${local.prefix}-etcd"
  key_vault_id = azurerm_key_vault.main[0].id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = local.etcd_key_opts

  lifecycle {
    prevent_destroy = false
  }
}

resource "azurerm_key_vault_key" "etcd_protected" {
  count = (local.kms_enabled && local.kms_prevent_destroy) ? 1 : 0

  name         = "${local.prefix}-etcd"
  key_vault_id = azurerm_key_vault.main[0].id
  key_type     = "RSA"
  key_size     = 2048

  key_opts = local.etcd_key_opts

  lifecycle {
    prevent_destroy = true
  }
}

// =====================================================================================
// AKS Cluster
// =====================================================================================

// trivy:ignore:AVD-AZU-0040 API server auth is via Entra RBAC; local accounts disabled.
// trivy:ignore:AVD-AZU-0041 Private cluster is configurable via cluster.private.enabled.
resource "azurerm_kubernetes_cluster" "main" {
  name                = local.cluster_name
  location            = azurerm_resource_group.main.location
  resource_group_name = azurerm_resource_group.main.name
  dns_prefix          = local.dns_prefix
  kubernetes_version  = local.kubernetes_version
  tags                = local.tags

  // Private-by-default control plane.
  private_cluster_enabled           = local.private_cluster_enabled
  role_based_access_control_enabled = true
  local_account_disabled            = true

  // OIDC issuer + workload identity (no secrets in pods).
  oidc_issuer_enabled       = local.oidc_issuer_enabled
  workload_identity_enabled = local.workload_identity_enabled

  identity {
    type = "SystemAssigned"
  }

  // Entra (Azure AD) RBAC integration.
  azure_active_directory_role_based_access_control {
    tenant_id              = data.azurerm_client_config.current.tenant_id
    azure_rbac_enabled     = true
    admin_group_object_ids = local.admin_group_object_ids
  }

  // API server access: authorized IP ranges only apply to public clusters
  // (private clusters have no public endpoint — the two are mutually exclusive).
  dynamic "api_server_access_profile" {
    for_each = local.private_cluster_enabled ? [] : [1]
    content {
      authorized_ip_ranges = local.authorized_ip_ranges
    }
  }

  // Default node pool == system pool. only_critical_addons_enabled applies the
  // CriticalAddonsOnly=true:NoSchedule taint so only system addons land here.
  default_node_pool {
    name                         = "system"
    vm_size                      = try(local.system_pool.vmSize, local.default_system_pool.vmSize)
    orchestrator_version         = local.kubernetes_version
    os_disk_type                 = try(local.system_pool.osDiskType, "Managed")
    os_disk_size_gb              = try(local.system_pool.osDiskSizeGb, 128)
    max_pods                     = try(local.system_pool.maxPods, local.default_max_pods)
    vnet_subnet_id               = azurerm_subnet.system.id
    only_critical_addons_enabled = true
    zones                        = local.zones

    auto_scaling_enabled = try(local.system_pool.autoscaling.enabled, true)
    min_count            = try(local.system_pool.autoscaling.enabled, true) ? try(local.system_pool.autoscaling.minNodes, 1) : null
    max_count            = try(local.system_pool.autoscaling.enabled, true) ? try(local.system_pool.autoscaling.maxNodes, 3) : null
    node_count           = try(local.system_pool.autoscaling.enabled, true) ? null : try(local.system_pool.size, 1)

    node_labels = try(local.system_pool.labels, {})

    upgrade_settings {
      max_surge = "10%"
    }
  }

  // Azure CNI with Azure network policy; service CIDR + kube-dns IP from config.
  network_profile {
    network_plugin    = "azure"
    network_policy    = "azure"
    load_balancer_sku = "standard"
    outbound_type     = local.nat_enabled ? "userAssignedNATGateway" : "loadBalancer"
    service_cidr      = local.service_cidr
    dns_service_ip    = local.dns_service_ip
  }

  // etcd KMS encryption (best-effort — see note above).
  dynamic "key_management_service" {
    for_each = local.kms_enabled ? [1] : []
    content {
      key_vault_key_id         = local.etcd_key_id
      key_vault_network_access = "Public"
    }
  }

  lifecycle {
    ignore_changes = [
      // Cluster autoscaler manages the running node count.
      default_node_pool[0].node_count,
    ]

    // A public cluster gates its API server with authorized_ip_ranges, which
    // must include the cluster's own egress IP so nodes can reach the API
    // server's public endpoint. That IP is only knowable in advance with a
    // NAT gateway; the loadBalancer outbound IP is AKS-managed and allocated
    // after creation, so the combination cannot work (nodes fail with
    // VMExtensionError_K8SAPIServerConnFail).
    precondition {
      condition     = local.private_cluster_enabled || local.nat_enabled
      error_message = "A public cluster (cluster.aks.private.enabled: false) requires the NAT gateway (network.aks.nat.enabled: true) so the node egress IP can be added to the API server authorized ranges."
    }
  }

  depends_on = [
    azurerm_subnet_nat_gateway_association.system,
    azurerm_subnet_nat_gateway_association.worker,
  ]

  timeouts {
    create = "45m"
    update = "45m"
    delete = "45m"
  }
}
