// =====================================================================================
// Status to standard output
// =====================================================================================

output "status" {
  description = "Deployment"
  value = {
    deployment = {
      project    = local.subscription
      region     = local.region
      updated    = local.update_time
      prefix     = local.prefix
      tags       = local.tags
      statusFile = local.status_file_path
    }
    access = {
      // Requires kubelogin for Entra RBAC auth (az aks install-cli / brew install kubelogin).
      command = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name} --overwrite-existing"
    }
  }
}

// =====================================================================================
// Status to JSON file (next to config file)
// =====================================================================================

locals {
  status_data = {
    apiVersion = "github.com/mchmarny/cluster/v1alpha1"
    kind       = "ClusterStatus"
    metadata = {
      name      = azurerm_kubernetes_cluster.main.name
      timestamp = local.update_time
    }
    deployment = {
      id      = local.prefix
      project = local.subscription
      region  = local.region
      tags    = local.tags
    }
    cluster = {
      name          = azurerm_kubernetes_cluster.main.name
      location      = azurerm_kubernetes_cluster.main.location
      version       = azurerm_kubernetes_cluster.main.kubernetes_version
      resourceGroup = azurerm_resource_group.main.name
      kubernetes = {
        endpoint             = azurerm_kubernetes_cluster.main.private_cluster_enabled ? azurerm_kubernetes_cluster.main.private_fqdn : azurerm_kubernetes_cluster.main.fqdn
        clusterCaCertificate = azurerm_kubernetes_cluster.main.kube_config[0].cluster_ca_certificate
        serviceCidr          = local.service_cidr
        dnsServiceIp         = local.dns_service_ip
        oidcIssuerUrl        = local.oidc_issuer_enabled ? azurerm_kubernetes_cluster.main.oidc_issuer_url : null
      }
      features = {
        workloadIdentity = local.workload_identity_enabled
        oidcIssuer       = local.oidc_issuer_enabled
        privateCluster   = local.private_cluster_enabled
      }
    }
    compute = {
      nodePools = concat(
        [
          {
            name         = "system"
            type         = "system"
            vmSize       = try(local.system_pool.vmSize, local.default_system_pool.vmSize)
            osDiskType   = try(local.system_pool.osDiskType, "Managed")
            osDiskSizeGb = try(local.system_pool.osDiskSizeGb, 128)
            minNodes     = try(local.system_pool.autoscaling.minNodes, 1)
            maxNodes     = try(local.system_pool.autoscaling.maxNodes, 3)
            gpu          = false
          }
        ],
        [
          for name, np in local.worker_pools : {
            name         = np.name
            type         = "worker"
            vmSize       = np.vm_size
            osDiskType   = np.os_disk_type
            osDiskSizeGb = np.os_disk_size
            minNodes     = np.min_nodes
            maxNodes     = np.max_nodes
            gpu          = np.is_gpu
          }
        ]
      )
    }
    network = {
      vnet = {
        id   = azurerm_virtual_network.main.id
        name = azurerm_virtual_network.main.name
        cidr = local.vnet_cidr
      }
      subnets = {
        system = {
          id   = azurerm_subnet.system.id
          name = azurerm_subnet.system.name
          cidr = local.system_subnet_cidr
        }
        worker = {
          id   = azurerm_subnet.worker.id
          name = azurerm_subnet.worker.name
          cidr = local.worker_subnet_cidr
        }
      }
      nat = local.nat_enabled ? {
        name     = azurerm_nat_gateway.main[0].name
        publicIp = azurerm_public_ip.nat[0].ip_address
        outbound = "userAssignedNATGateway"
      } : null
    }
    security = {
      kms = local.kms_enabled ? {
        keyVault = azurerm_key_vault.main[0].name
        key      = local.kms_prevent_destroy ? azurerm_key_vault_key.etcd_protected[0].name : azurerm_key_vault_key.etcd[0].name
      } : null
      identity = {
        cluster = azurerm_kubernetes_cluster.main.identity[0].principal_id
        kubelet = azurerm_kubernetes_cluster.main.kubelet_identity[0].object_id
      }
      rbac = {
        azureRbac     = true
        adminGroups   = local.admin_group_object_ids
        localDisabled = true
      }
    }
    access = {
      az = {
        command = "az aks get-credentials --resource-group ${azurerm_resource_group.main.name} --name ${azurerm_kubernetes_cluster.main.name} --overwrite-existing"
      }
      kubectl = {
        command = "kubectl config use-context ${azurerm_kubernetes_cluster.main.name}"
      }
    }
  }
}

// Write status to JSON file
resource "local_file" "status" {
  filename = local.status_file_path
  content  = jsonencode(local.status_data)

  file_permission      = "0644"
  directory_permission = "0755"
}
