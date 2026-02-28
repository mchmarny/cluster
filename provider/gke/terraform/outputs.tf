// =====================================================================================
// Status to standard output
// =====================================================================================

output "deployment" {
  description = "Deployment information"
  value = {
    project = local.project
    region  = local.region
    updated = local.updateTime
    prefix  = local.prefix
    tags    = try(local.config.deployment.tags, {})
  }
}

// =====================================================================================
// Status to YAML file (next to config file)
// =====================================================================================

locals {
  status_data = {
    apiVersion = "github.com/mchmarny/cluster/v1alpha1"
    kind       = "ClusterStatus"
    metadata = {
      name      = google_container_cluster.main.name
      timestamp = local.updateTime
    }
    deployment = {
      id      = local.prefix
      project = local.project
      region  = local.region
      tags    = try(local.config.deployment.tags, {})
    }
    cluster = {
      name     = google_container_cluster.main.name
      location = google_container_cluster.main.location
      version  = google_container_cluster.main.master_version
      kubernetes = {
        endpoint             = google_container_cluster.main.endpoint
        clusterCaCertificate = google_container_cluster.main.master_auth[0].cluster_ca_certificate
        serviceCidr          = google_container_cluster.main.services_ipv4_cidr
        clusterCidr          = google_container_cluster.main.cluster_ipv4_cidr
      }
      features = {
        workloadIdentity    = local.workload_identity_enabled
        binaryAuthorization = local.binary_authorization_enabled
      }
    }
    compute = {
      nodePools = [
        for np in local.all_node_pools : {
          name             = np.name
          type             = np.type
          machineType      = np.machineType
          imageType        = try(np.imageType, "COS_CONTAINERD")
          diskType         = try(np.diskType, "pd-standard")
          diskSizeGb       = try(np.diskSizeGb, 100)
          minNodes         = try(np.autoscaling.minNodes, 1)
          maxNodes         = try(np.autoscaling.maxNodes, 3)
          nodeCount        = try(google_container_node_pool.pools[np.name].node_count, 0)
          locations        = try(google_container_node_pool.pools[np.name].node_locations, [])
          version          = try(google_container_node_pool.pools[np.name].version, google_container_cluster.main.master_version)
          status           = try(google_container_node_pool.pools[np.name].status, "UNKNOWN")
          accelerator      = try(np.guestAccelerator.type, null)
          acceleratorCount = try(np.guestAccelerator.count, 0)
        }
      ]
    }
    network = {
      vpc = {
        id       = google_compute_network.main.id
        name     = google_compute_network.main.name
        selfLink = google_compute_network.main.self_link
      }
      subnets = {
        for name, subnet in google_compute_subnetwork.main : name => {
          id     = subnet.id
          name   = subnet.name
          cidr   = subnet.ip_cidr_range
          region = subnet.region
          secondaryRanges = [
            for range in subnet.secondary_ip_range : {
              rangeName = range.range_name
              cidr      = range.ip_cidr_range
            }
          ]
        }
      }
      nat = local.nat_enabled ? {
        router = google_compute_router.main[0].name
        nat    = google_compute_router_nat.main[0].name
        region = google_compute_router.main[0].region
      } : null
      firewallRules = {
        for name, rule in google_compute_firewall.rules : name => {
          name      = rule.name
          direction = rule.direction
          priority  = rule.priority
        }
      }
    }
    security = {
      kms = local.secrets_encryption_enabled ? {
        keyRing   = google_kms_key_ring.gke[0].name
        cryptoKey = google_kms_crypto_key.gke_secrets[0].name
        location  = google_kms_key_ring.gke[0].location
      } : null
      serviceAccounts = {
        systemNodes = google_service_account.system_nodes.email
        workerNodes = google_service_account.worker_nodes.email
      }
      shieldedNodes = {
        secureBoot          = local.secure_boot_enabled
        integrityMonitoring = local.integrity_monitoring_enabled
      }
    }
    access = {
      gcloud = {
        command = "gcloud container clusters get-credentials ${google_container_cluster.main.name} --region ${local.region} --project ${local.project}"
      }
      kubectl = {
        command = "kubectl config use-context gke_${local.project}_${local.region}_${google_container_cluster.main.name}"
      }
    }
  }
}

// Write status to YAML file
resource "local_file" "status" {
  filename = local.statusFilePath
  content  = jsonencode(local.status_data)

  file_permission      = "0644"
  directory_permission = "0755"
}
