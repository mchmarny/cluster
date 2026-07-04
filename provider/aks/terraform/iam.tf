// =====================================================================================
// Role Assignments
// =====================================================================================

// The AKS control-plane (SystemAssigned) identity needs Network Contributor on
// the VNet to manage load balancers, the NAT gateway association, and to attach
// node NICs to the custom subnets. Scoped to the VNet, not the subscription.
resource "azurerm_role_assignment" "cluster_network_contributor" {
  scope                = azurerm_virtual_network.main.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_kubernetes_cluster.main.identity[0].principal_id
}

// The kubelet identity pulls images; grant AcrPull at the resource-group scope
// so any ACR provisioned alongside the cluster is readable without secrets.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  scope                = azurerm_resource_group.main.id
  role_definition_name = "AcrPull"
  principal_id         = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
}
