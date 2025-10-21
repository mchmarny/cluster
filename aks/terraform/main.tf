data "azurerm_client_config" "current" {}

data "azurerm_subscription" "current" {}

data "http" "egress_ip" {
  url             = "https://checkip.amazonaws.com"
  request_headers = { Accept = "text/plain" }
}

locals {
  // Load configuration from YAML file
  config = yamldecode(file(var.CONFIG_PATH))

  configDir      = dirname(var.CONFIG_PATH)
  configFilename = basename(var.CONFIG_PATH)
  configBasename = replace(local.configFilename, "/\\.ya?ml$/", "")
  statusFilePath = "${local.configDir}/${local.configBasename}-status.json"

  // Update time
  updateTime = formatdate("YYYYMMDD-HHmmss", timestamp())

  // Extract required deployment settings
  prefix              = local.config.deployment.id
  subscription_id     = local.config.deployment.tenancy
  resource_group_name = local.config.deployment.azure.resourceGroup
  location            = local.config.deployment.location
  egress_cidr         = "${trimspace(data.http.egress_ip.response_body)}/32"

  // Extract optional deployment settings with defaults
  aks_version         = try(local.config.cluster.version, "1.30")
  cluster_name        = try(local.config.cluster.name, "${local.prefix}-aks")
  deletion_protection = try(local.config.deployment.deletionProtection, true)

  // Network configuration
  vnet_address_space = local.config.network.vnetAddressSpace
  pod_cidr           = local.config.network.podCidr
  service_cidr       = local.config.network.serviceCidr
  dns_service_ip     = local.config.network.dnsServiceIp
  network_plugin     = try(local.config.network.networkPlugin, "azure")
  network_mode       = try(local.config.network.networkMode, "transparent")
  network_policy     = try(local.config.security.networkPolicy, "azure")
  outbound_type      = try(local.config.network.outboundType, "loadBalancer")

  // Private cluster settings
  private_cluster_enabled      = try(local.config.cluster.private.enabled, true)
  private_dns_zone_id          = try(local.config.cluster.private.privateDnsZoneId, null)
  api_server_authorized_ranges = concat(try(local.config.cluster.controlPlane.authorizedIpRanges, []), [local.egress_cidr])

  // Features
  workload_identity_enabled        = try(local.config.cluster.features.workloadIdentity, true)
  oidc_issuer_enabled              = try(local.config.cluster.features.oidcIssuer, true)
  azure_keyvault_secrets_provider  = try(local.config.cluster.features.azureKeyVaultSecretsProvider, true)
  azure_policy_enabled             = try(local.config.cluster.features.azurePolicy, false)
  defender_enabled                 = try(local.config.security.defenderEnabled, false)
  http_application_routing_enabled = try(local.config.cluster.addons.httpApplicationRouting, false)

  // RBAC and security
  local_account_disabled = try(local.config.security.localAccounts, false) == false
  rbac_enabled           = try(local.config.security.rbac, true)

  // Tags
  tags = merge(
    try(local.config.deployment.tags, {}),
    {
      "deployment-id" = local.prefix
      "managed-by"    = "terraform"
      "last-updated"  = local.updateTime
    }
  )

  // Node pool configuration
  node_pools = try(local.config.compute.nodePools, {})

  // Find system node pool (required for AKS)
  system_node_pool_key = [
    for k, v in local.node_pools : k
    if try(v.mode, "User") == "System"
  ][0]
  system_node_pool = local.node_pools[local.system_node_pool_key]

  // User node pools (all non-system pools)
  user_node_pools = {
    for k, v in local.node_pools : k => v
    if try(v.mode, "User") == "User"
  }
}
