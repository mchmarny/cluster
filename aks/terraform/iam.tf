// User-assigned managed identity for kubelet (used by node pools)
resource "azurerm_user_assigned_identity" "kubelet" {
  name                = "${local.cluster_name}-kubelet-identity"
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = local.tags
}

// Get the node resource group (created by AKS)
data "azurerm_resource_group" "node" {
  name       = azurerm_kubernetes_cluster.main.node_resource_group
  depends_on = [azurerm_kubernetes_cluster.main]
}

// Role assignment: AKS cluster identity -> Network Contributor on VNet
resource "azurerm_role_assignment" "aks_network" {
  scope                            = azurerm_virtual_network.main.id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_kubernetes_cluster.main.identity[0].principal_id
  skip_service_principal_aad_check = true
}

// Role assignment: AKS cluster identity -> Network Contributor on node resource group
resource "azurerm_role_assignment" "aks_node_rg" {
  scope                            = data.azurerm_resource_group.node.id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_kubernetes_cluster.main.identity[0].principal_id
  skip_service_principal_aad_check = true
}

// Role assignment: Kubelet identity -> Managed Identity Operator on node resource group
resource "azurerm_role_assignment" "kubelet_mi_operator" {
  scope                            = data.azurerm_resource_group.node.id
  role_definition_name             = "Managed Identity Operator"
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

// Role assignment: Kubelet identity -> Virtual Machine Contributor on node resource group
resource "azurerm_role_assignment" "kubelet_vm_contributor" {
  scope                            = data.azurerm_resource_group.node.id
  role_definition_name             = "Virtual Machine Contributor"
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

// Optional: Role assignment for ACR access
resource "azurerm_role_assignment" "aks_acr" {
  count = try(local.config.security.acrId, null) != null ? 1 : 0

  scope                            = local.config.security.acrId
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  skip_service_principal_aad_check = true
}

// Optional: Role assignment for Key Vault access
resource "azurerm_role_assignment" "aks_keyvault" {
  count = try(local.config.security.keyVaultId, null) != null && local.azure_keyvault_secrets_provider ? 1 : 0

  scope                            = local.config.security.keyVaultId
  role_definition_name             = "Key Vault Secrets User"
  principal_id                     = azurerm_kubernetes_cluster.main.key_vault_secrets_provider[0].secret_identity[0].object_id
  skip_service_principal_aad_check = true
}

// Optional: Role assignment for monitoring
resource "azurerm_role_assignment" "aks_monitoring" {
  count = try(local.config.monitoring.logAnalyticsWorkspaceId, null) != null ? 1 : 0

  scope                            = local.config.monitoring.logAnalyticsWorkspaceId
  role_definition_name             = "Monitoring Metrics Publisher"
  principal_id                     = azurerm_kubernetes_cluster.main.oms_agent[0].oms_agent_identity[0].object_id
  skip_service_principal_aad_check = true
}

// Workload Identity Federation for application workloads
// Example: Create federated identity for a specific namespace/service account

resource "azurerm_user_assigned_identity" "workload" {
  for_each = try(local.config.iam.workloadIdentities, {})

  name                = "${local.cluster_name}-${each.key}-identity"
  location            = local.location
  resource_group_name = local.resource_group_name
  tags                = merge(local.tags, { "workload" = each.key })
}

resource "azurerm_federated_identity_credential" "workload" {
  for_each = try(local.config.iam.workloadIdentities, {})

  name                = "${local.cluster_name}-${each.key}-federated"
  resource_group_name = local.resource_group_name
  parent_id           = azurerm_user_assigned_identity.workload[each.key].id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = azurerm_kubernetes_cluster.main.oidc_issuer_url
  subject             = "system:serviceaccount:${each.value.namespace}:${each.value.serviceAccount}"
}

// Role assignments for workload identities
resource "azurerm_role_assignment" "workload" {
  for_each = {
    for k, v in try(local.config.iam.workloadIdentities, {}) : k => v
    if try(v.roleAssignments, null) != null
  }

  scope                            = each.value.roleAssignments.scope
  role_definition_name             = each.value.roleAssignments.role
  principal_id                     = azurerm_user_assigned_identity.workload[each.key].principal_id
  skip_service_principal_aad_check = true
}

// Optional: Storage account access for workloads (e.g., for blob CSI driver)
resource "azurerm_role_assignment" "workload_storage" {
  for_each = {
    for k, v in try(local.config.iam.workloadIdentities, {}) : k => v
    if try(v.storageAccountId, null) != null
  }

  scope                            = each.value.storageAccountId
  role_definition_name             = "Storage Blob Data Contributor"
  principal_id                     = azurerm_user_assigned_identity.workload[each.key].principal_id
  skip_service_principal_aad_check = true
}
