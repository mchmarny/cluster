data "azurerm_client_config" "current" {}

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

  // Network configuration with defaults
  // Default: 10.0.0.0/16 for VNet, auto-computed subnets
  vnet_address_space = try(local.config.network.vnetAddressSpace, "10.0.0.0/16")

  // Auto-compute subnet CIDRs from VNet CIDR if not specified
  // Layout: system=/24, worker=/24, pods=/20, services=/24, appgw=/24
  system_subnet_cidr  = try(local.config.network.systemSubnetCidr, cidrsubnet(local.vnet_address_space, 8, 1))   // 10.0.1.0/24
  worker_subnet_cidr  = try(local.config.network.workerSubnetCidr, cidrsubnet(local.vnet_address_space, 8, 2))   // 10.0.2.0/24
  pod_subnet_cidr     = try(local.config.network.podSubnetCidr, cidrsubnet(local.vnet_address_space, 4, 1))      // 10.0.16.0/20

  // Service CIDR (non-overlapping with VNet)
  service_cidr   = try(local.config.network.serviceCidr, try(local.config.cluster.controlPlane.cidr, "172.20.0.0/16"))
  dns_service_ip = try(local.config.network.dnsServiceIp, try(local.config.cluster.controlPlane.dnsServiceIp, cidrhost(local.service_cidr, 10)))
  pod_cidr       = try(local.config.network.podCidr, "10.244.0.0/16")

  network_plugin = try(local.config.network.networkPlugin, "azure")
  network_mode   = try(local.config.network.networkMode, "transparent")
  network_policy = try(local.config.security.networkPolicy, "azure")
  outbound_type  = try(local.config.network.outboundType, "loadBalancer")

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

  // Default node pool configuration
  default_system_pool = {
    system = {
      type               = "system"
      mode               = "System"
      vmSize             = "Standard_D4s_v5"
      osDiskSizeGb       = 128
      nodeCount          = 3
      enableAutoScaling  = true
      minCount           = 2
      maxCount           = 10
      maxPods            = 30
      availabilityZones  = ["1", "2", "3"]
      nodeLabels         = { "node-type" = "system" }
      nodeTaints         = []
    }
  }

  // Merge user-provided node pools with defaults
  node_pools = length(try(local.config.compute.nodePools, {})) > 0 ? local.config.compute.nodePools : local.default_system_pool

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
