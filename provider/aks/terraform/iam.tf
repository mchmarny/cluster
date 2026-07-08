// =====================================================================================
// Role Assignments
// =====================================================================================
//
// Creating these requires Microsoft.Authorization/roleAssignments/write
// (Owner, User Access Administrator, or RBAC Administrator — ideally the
// latter with an ABAC condition limiting assignable roles; see README).
// Deployers with plain Contributor can set iam.roleAssignments: false to
// skip them; the cluster deploys fine but LoadBalancer services in the BYO
// VNet and ACR pulls will not work until the grants exist.
//
// Both assignments target a principal minted seconds earlier by cluster
// creation. Entra replication lag makes ARM's principal-existence check
// intermittently fail for new principals, so it is skipped explicitly
// (principal_type is then required for correct evaluation).

// The AKS control-plane (SystemAssigned) identity needs Network Contributor on
// the VNet to manage load balancers, the NAT gateway association, and to attach
// node NICs to the custom subnets. Scoped to the VNet, not the subscription.
resource "azurerm_role_assignment" "cluster_network_contributor" {
  count = local.iam_role_assignments ? 1 : 0

  scope                            = azurerm_virtual_network.main.id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_kubernetes_cluster.main.identity[0].principal_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}

// The kubelet identity pulls images; grant AcrPull at the resource-group scope
// so any ACR provisioned alongside the cluster is readable without secrets.
resource "azurerm_role_assignment" "kubelet_acr_pull" {
  count = local.iam_role_assignments ? 1 : 0

  scope                            = azurerm_resource_group.main.id
  role_definition_name             = "AcrPull"
  principal_id                     = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
  principal_type                   = "ServicePrincipal"
  skip_service_principal_aad_check = true
}
