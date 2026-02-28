data "google_project" "current" {
  project_id = local.project
}

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
  // Must only contain lowercase letters ([a-z]), numeric characters ([0-9]), underscores (_) and dashes (-).
  updateTime = formatdate("YYYYMMDD-HHmmss", timestamp())

  // Extract required deployment settings
  prefix      = local.config.deployment.id
  project     = local.config.deployment.tenancy
  region      = local.config.deployment.location
  egress_cidr = "${trimspace(data.http.egress_ip.response_body)}/32"

  // Cluster name (defaults to deployment.id)
  cluster_name = try(local.config.cluster.name, local.prefix)

  // Extract optional deployment settings with defaults
  gke_version         = try(local.config.cluster.version, null)
  release_channel     = try(local.config.cluster.releaseChannel, "STABLE")
  deletion_protection = try(local.config.cluster.deletionProtection, false)

  // Cluster features
  workload_identity_enabled = try(local.config.cluster.features.workloadIdentity, true)
  filestore_csi_enabled     = try(local.config.cluster.features.gcpFilestoreCsiDriver, false)
  gcs_fuse_csi_enabled      = try(local.config.cluster.features.gcsFuseCsiDriver, false)

  // Private cluster
  private_cluster_enabled = try(local.config.cluster.private.enabled, true)
  master_ipv4_cidr_block  = try(local.config.cluster.private.masterIpv4CidrBlock, "172.16.0.0/28")

  // Security
  binary_authorization_enabled = try(local.config.security.binaryAuthorization.enabled, false)
  secrets_encryption_enabled   = try(local.config.security.secretsEncryption.enabled, true)
  secure_boot_enabled          = try(local.config.security.shieldedNodes.secureBoot, true)
  integrity_monitoring_enabled = try(local.config.security.shieldedNodes.integrityMonitoring, true)

  // Network defaults
  vpc_name = try(local.config.network.name, "${local.prefix}-vpc")
  vpc_cidr = try(local.config.network.cidr, "10.0.0.0/16")

  // NAT configuration
  nat_enabled                     = try(local.config.network.nat.enabled, true)
  nat_source_subnetwork_ip_ranges = try(local.config.network.nat.sourceSubnetIpRangesToNat, "ALL_SUBNETWORKS_ALL_IP_RANGES")
  nat_min_ports_per_vm            = try(local.config.network.nat.minPortsPerVm, 64)

  // Maintenance window
  maintenance_start_time = try(local.config.cluster.maintenance.window.startTime, "03:00")

  // Default subnet configuration (auto-computed from VPC CIDR)
  default_node_subnets = [
    {
      name                = "system-subnet"
      cidr                = cidrsubnet(local.vpc_cidr, 6, 0) // 10.0.0.0/22
      privateGoogleAccess = true
    },
    {
      name                = "worker-subnet"
      cidr                = cidrsubnet(local.vpc_cidr, 1, 1) // 10.0.128.0/17
      privateGoogleAccess = true
    }
  ]

  // Default secondary ranges for pods and services
  default_secondary_ranges = {
    "system-subnet" = {
      pods = {
        rangeName = "system-pods"
        cidr      = "10.100.0.0/17"
      }
      services = {
        rangeName = "system-services"
        cidr      = "172.20.0.0/22"
      }
    }
    "worker-subnet" = {
      pods = {
        rangeName = "worker-pods"
        cidr      = "10.100.128.0/17"
      }
      services = {
        rangeName = "worker-services"
        cidr      = "172.20.128.0/17"
      }
    }
  }

  // Process node subnets (use config or defaults)
  node_subnets = {
    for subnet in try(local.config.network.subnets.nodes, local.default_node_subnets) :
    subnet.name => subnet
  }

  // Process secondary ranges (use config or defaults)
  secondary_ranges = {
    for subnet_name, ranges in try(local.config.network.subnets.secondary, local.default_secondary_ranges) :
    subnet_name => ranges
  }

  // Default system node pool configuration
  default_system_pool = {
    machineType = "e2-standard-4"
    imageType   = "COS_CONTAINERD"
    diskType    = "pd-standard"
    diskSizeGb  = 100
    autoscaling = {
      enabled        = true
      minNodes       = 1
      maxNodes       = 3
      locationPolicy = "BALANCED"
    }
    autoUpgrade = true
    autoRepair  = true
    nodeConfig = {
      preemptible = false
      spot        = false
      tags        = ["gke-node", "system-node"]
      labels      = { nodeGroup = "system" }
      taints = [
        { key = "dedicated", value = "CriticalAddonsOnly", effect = "NO_SCHEDULE" }
      ]
      metadata    = { "disable-legacy-endpoints" = "true" }
      oauthScopes = ["https://www.googleapis.com/auth/cloud-platform"]
      shieldedInstanceConfig = {
        enableSecureBoot          = true
        enableIntegrityMonitoring = true
      }
    }
  }

  // Flatten node pools structure: system object + workers array
  system_pool_config = try(local.config.compute.nodePools.system, local.default_system_pool)

  all_node_pools = concat(
    # Add system node pool with name and type
    [
      merge(
        local.system_pool_config,
        {
          name = "system"
          type = "system"
        }
      )
    ],
    # Add workers array with type attribute
    [
      for worker in try(local.config.compute.nodePools.workers, []) :
      merge(
        worker,
        {
          type = "worker"
        }
      )
    ]
  )

  // Create authorized networks list
  authorized_networks = concat(
    [for net in try(local.config.cluster.controlPlane.authorizedNetworks, []) : {
      cidr_block   = net.cidr
      display_name = net.name
    }],
    [{
      cidr_block   = local.egress_cidr
      display_name = "terraform-executor"
    }]
  )
}

// =====================================================================================
// Validation 
// =====================================================================================

check "project_matches" {
  assert {
    condition     = data.google_project.current.project_id == local.project
    error_message = "Invalid GCP project (want: ${local.project}, got: ${data.google_project.current.project_id})."
  }
}
