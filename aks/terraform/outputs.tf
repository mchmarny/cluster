locals {
  status_data = {
    apiVersion = "v1"
    kind       = "ClusterStatus"
    metadata = {
      name              = local.cluster_name
      deploymentId      = local.prefix
      cloud             = "azure"
      location          = local.location
      subscriptionId    = local.subscription_id
      resourceGroup     = local.resource_group_name
      nodeResourceGroup = azurerm_kubernetes_cluster.main.node_resource_group
      createdAt         = local.updateTime
    }
    cluster = {
      name                    = azurerm_kubernetes_cluster.main.name
      id                      = azurerm_kubernetes_cluster.main.id
      version                 = azurerm_kubernetes_cluster.main.kubernetes_version
      skuTier                 = azurerm_kubernetes_cluster.main.sku_tier
      fqdn                    = azurerm_kubernetes_cluster.main.fqdn
      privateFqdn             = local.private_cluster_enabled ? azurerm_kubernetes_cluster.main.private_fqdn : null
      apiServerEndpoint       = local.private_cluster_enabled ? azurerm_kubernetes_cluster.main.private_fqdn : azurerm_kubernetes_cluster.main.fqdn
      kubeAdminConfig         = "az aks get-credentials --resource-group ${local.resource_group_name} --name ${local.cluster_name} --admin"
      kubeUserConfig          = "az aks get-credentials --resource-group ${local.resource_group_name} --name ${local.cluster_name}"
      oidcIssuerUrl           = local.oidc_issuer_enabled ? azurerm_kubernetes_cluster.main.oidc_issuer_url : null
      workloadIdentityEnabled = local.workload_identity_enabled
      features = {
        privateCluster          = local.private_cluster_enabled
        workloadIdentity        = local.workload_identity_enabled
        oidcIssuer              = local.oidc_issuer_enabled
        keyVaultSecretsProvider = local.azure_keyvault_secrets_provider
        azurePolicy             = local.azure_policy_enabled
        defender                = local.defender_enabled
        localAccountsDisabled   = local.local_account_disabled
      }
    }
    network = {
      vnet = {
        name         = azurerm_virtual_network.main.name
        id           = azurerm_virtual_network.main.id
        addressSpace = azurerm_virtual_network.main.address_space
      }
      subnets = {
        system = {
          name         = azurerm_subnet.system.name
          id           = azurerm_subnet.system.id
          addressRange = azurerm_subnet.system.address_prefixes[0]
        }
        worker = {
          name         = azurerm_subnet.worker.name
          id           = azurerm_subnet.worker.id
          addressRange = azurerm_subnet.worker.address_prefixes[0]
        }
        pods = local.network_plugin == "azure" && try(local.config.network.podSubnetCidr, null) != null ? {
          name         = azurerm_subnet.pods[0].name
          id           = azurerm_subnet.pods[0].id
          addressRange = azurerm_subnet.pods[0].address_prefixes[0]
        } : null
      }
      networkSecurityGroups = {
        system = {
          name = azurerm_network_security_group.system.name
          id   = azurerm_network_security_group.system.id
        }
        worker = {
          name = azurerm_network_security_group.worker.name
          id   = azurerm_network_security_group.worker.id
        }
        pods = local.network_plugin == "azure" && try(local.config.network.podSubnetCidr, null) != null ? {
          name = azurerm_network_security_group.pods[0].name
          id   = azurerm_network_security_group.pods[0].id
        } : null
      }
      networkProfile = {
        networkPlugin = local.network_plugin
        networkMode   = local.network_mode
        networkPolicy = local.network_policy
        podCidr       = local.network_plugin == "kubenet" ? local.pod_cidr : null
        serviceCidr   = local.service_cidr
        dnsServiceIp  = local.dns_service_ip
        outboundType  = local.outbound_type
      }
      natGateway = local.outbound_type == "natGateway" ? {
        name     = azurerm_nat_gateway.main[0].name
        id       = azurerm_nat_gateway.main[0].id
        publicIp = azurerm_public_ip.nat[0].ip_address
      } : null
    }
    compute = {
      defaultNodePool = {
        name               = azurerm_kubernetes_cluster.main.default_node_pool[0].name
        vmSize             = azurerm_kubernetes_cluster.main.default_node_pool[0].vm_size
        availabilityZones  = azurerm_kubernetes_cluster.main.default_node_pool[0].zones
        autoScalingEnabled   = azurerm_kubernetes_cluster.main.default_node_pool[0].auto_scaling_enabled
        minCount           = azurerm_kubernetes_cluster.main.default_node_pool[0].min_count
        maxCount           = azurerm_kubernetes_cluster.main.default_node_pool[0].max_count
        currentNodeCount   = azurerm_kubernetes_cluster.main.default_node_pool[0].node_count
        maxPods            = azurerm_kubernetes_cluster.main.default_node_pool[0].max_pods
        osDiskSizeGb       = azurerm_kubernetes_cluster.main.default_node_pool[0].os_disk_size_gb
        vnetSubnetId       = azurerm_kubernetes_cluster.main.default_node_pool[0].vnet_subnet_id
        podSubnetId        = azurerm_kubernetes_cluster.main.default_node_pool[0].pod_subnet_id
      }
      additionalNodePools = {
        for k, v in azurerm_kubernetes_cluster_node_pool.user : k => {
          name               = v.name
          vmSize             = v.vm_size
          availabilityZones  = v.zones
          autoScalingEnabled   = v.auto_scaling_enabled
          minCount           = v.min_count
          maxCount           = v.max_count
          currentNodeCount   = v.node_count
          maxPods            = v.max_pods
          osDiskSizeGb       = v.os_disk_size_gb
          osType             = v.os_type
          priority           = v.priority
          vnetSubnetId       = v.vnet_subnet_id
          podSubnetId        = v.pod_subnet_id
        }
      }
    }
    iam = {
      clusterIdentity = {
        type        = azurerm_kubernetes_cluster.main.identity[0].type
        principalId = azurerm_kubernetes_cluster.main.identity[0].principal_id
        tenantId    = azurerm_kubernetes_cluster.main.identity[0].tenant_id
      }
      kubeletIdentity = {
        clientId               = azurerm_kubernetes_cluster.main.kubelet_identity[0].client_id
        objectId               = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
        userAssignedIdentityId = azurerm_kubernetes_cluster.main.kubelet_identity[0].user_assigned_identity_id
      }
      keyVaultSecretsProvider = local.azure_keyvault_secrets_provider ? {
        clientId = azurerm_kubernetes_cluster.main.key_vault_secrets_provider[0].secret_identity[0].client_id
        objectId = azurerm_kubernetes_cluster.main.key_vault_secrets_provider[0].secret_identity[0].object_id
      } : null
      workloadIdentities = {
        for k, v in azurerm_user_assigned_identity.workload : k => {
          name        = v.name
          id          = v.id
          clientId    = v.client_id
          principalId = v.principal_id
        }
      }
    }
    security = {
      authorizedIpRanges    = local.api_server_authorized_ranges
      localAccountsDisabled = local.local_account_disabled
      rbacEnabled           = local.rbac_enabled
      azureRbacEnabled      = azurerm_kubernetes_cluster.main.azure_active_directory_role_based_access_control[0].azure_rbac_enabled
      azurePolicyEnabled    = local.azure_policy_enabled
      defenderEnabled       = local.defender_enabled
    }
  }
}

output "status" {
  description = "Comprehensive cluster deployment status and access information"
  value = {
    deployment = {
      id             = local.prefix
      subscriptionId = local.subscription_id
      resourceGroup  = local.resource_group_name
      location       = local.location
      timestamp      = local.updateTime
    }
    cluster = {
      name     = azurerm_kubernetes_cluster.main.name
      version  = azurerm_kubernetes_cluster.main.kubernetes_version
      endpoint = local.private_cluster_enabled ? azurerm_kubernetes_cluster.main.private_fqdn : azurerm_kubernetes_cluster.main.fqdn
    }
    access = {
      kubeconfigAdmin = "az aks get-credentials --resource-group ${local.resource_group_name} --name ${local.cluster_name} --admin"
      kubeconfigUser  = "az aks get-credentials --resource-group ${local.resource_group_name} --name ${local.cluster_name}"
      portal          = "https://portal.azure.com/#resource${azurerm_kubernetes_cluster.main.id}"
    }
    statusFile = local.statusFilePath
  }
}

# Write detailed status to JSON file
resource "local_file" "status" {
  content  = jsonencode(local.status_data)
  filename = local.statusFilePath

  depends_on = [
    azurerm_kubernetes_cluster.main,
    azurerm_kubernetes_cluster_node_pool.user
  ]
}
