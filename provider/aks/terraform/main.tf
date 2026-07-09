data "azurerm_client_config" "current" {}

data "http" "egress_ip" {
  url             = "https://api.ipify.org"
  request_headers = { Accept = "text/plain" }
}

locals {
  // Load configuration from YAML file
  config = yamldecode(file(var.CONFIG_PATH))

  config_dir       = dirname(var.CONFIG_PATH)
  config_filename  = basename(var.CONFIG_PATH)
  config_basename  = replace(local.config_filename, "/\\.ya?ml$/", "")
  status_file_path = "${local.config_dir}/${local.config_basename}-status.json"

  // Update time (mirrors GKE/EKS status envelope)
  // Must only contain lowercase letters ([a-z]), numeric characters ([0-9]), underscores (_) and dashes (-).
  update_time = formatdate("YYYYMMDD-HHmmss", timestamp())

  // Extract required deployment settings.
  // deployment.tenancy -> Azure subscription ID (consistent naming across CSPs).
  prefix       = local.config.deployment.id
  subscription = local.config.deployment.tenancy
  region       = local.config.deployment.location
  egress_cidr  = "${trimspace(data.http.egress_ip.response_body)}/32"

  // Tags applied to every resource (azurerm has no provider-level default_tags).
  tags = try(local.config.deployment.tags, {})

  // Cluster identity
  cluster_name        = try(local.config.cluster.aks.name, local.prefix)
  resource_group_name = try(local.config.cluster.aks.resourceGroup, "${local.prefix}-rg")
  kubernetes_version  = try(local.config.cluster.aks.version, null)

  // Cluster DNS prefix must be alphanumeric + hyphens, start/end alphanumeric.
  dns_prefix = replace(local.cluster_name, "/[^a-zA-Z0-9-]/", "-")

  // Azure AD / Entra RBAC admin groups (object IDs)
  admin_group_object_ids = try(local.config.cluster.aks.adminGroups, [])

  // Private cluster toggle (private by default).
  //
  // NOTE (live-validate): AKS treats private_cluster_enabled = true and
  // api_server_access_profile.authorized_ip_ranges as MUTUALLY EXCLUSIVE — a
  // fully private API server has no public endpoint to gate with IP ranges.
  // We therefore only emit authorized_ip_ranges when the cluster is public.
  // This mirrors GKE's real behavior (private nodes + restricted control plane
  // corresponds to private_cluster_enabled = false + authorized_ip_ranges).
  private_cluster_enabled = try(local.config.cluster.aks.private.enabled, true)

  // Cluster features
  workload_identity_enabled = try(local.config.cluster.aks.features.workloadIdentity, true)
  oidc_issuer_enabled       = try(local.config.cluster.aks.features.oidcIssuer, true)

  // Role assignments for the cluster identities (see iam.tf). Requires
  // roleAssignments/write on the deployer; disable for Contributor-only runs.
  iam_role_assignments = try(local.config.cluster.aks.iam.roleAssignments, true)

  // etcd KMS encryption via Key Vault key.
  //
  // NOTE (live-validate): Defaulted to false. KMS etcd encryption requires a
  // Key Vault with purge protection enabled, which imposes a 90-day soft-delete
  // retention that blocks clean teardown of a create/destroy demo cluster.
  // Enable explicitly via security.kmsEncryption.enabled for production.
  kms_enabled         = try(local.config.security.kmsEncryption.enabled, false)
  kms_prevent_destroy = try(local.config.security.kmsEncryption.preventDestroy, false)

  etcd_key_opts = ["decrypt", "encrypt", "sign", "unwrapKey", "verify", "wrapKey"]

  // Selects protected vs unprotected key based on kms_prevent_destroy (GKE-style).
  etcd_key_id = local.kms_enabled ? (
    local.kms_prevent_destroy
    ? azurerm_key_vault_key.etcd_protected[0].id
    : azurerm_key_vault_key.etcd[0].id
  ) : null

  // Network defaults
  vnet_cidr      = try(local.config.network.aks.cidr, "10.0.0.0/16")
  service_cidr   = try(local.config.network.aks.serviceCidr, "172.20.0.0/16")
  dns_service_ip = try(local.config.network.aks.dnsServiceIp, "172.20.0.10")

  // Subnets — default to non-overlapping ranges carved from the VNet CIDR.
  system_subnet_cidr = try(local.config.network.aks.subnets.system.cidr, cidrsubnet(local.vnet_cidr, 6, 0)) // 10.0.0.0/22
  worker_subnet_cidr = try(local.config.network.aks.subnets.worker.cidr, cidrsubnet(local.vnet_cidr, 1, 1)) // 10.0.128.0/17

  // NAT gateway for private-node egress (enabled by default).
  nat_enabled = try(local.config.network.aks.nat.enabled, true)

  // Availability zones for node pools and the NAT public IP. Regions without
  // AZ support (e.g. westus) require an empty list: `cluster.aks.zones: []`.
  zones = try(local.config.cluster.aks.zones, ["1", "2", "3"])

  // H100 GPU SKU used as the documented default when a worker sets gpuType.
  // (live-validate) confirm SKU availability/quota in the target region.
  gpu_default_vm_size = "Standard_ND96isr_H100_v5"

  // Default pods-per-node. AKS's own default (30) is tight for real
  // workloads; updating it on a live pool rolls the pool's nodes.
  // With node-subnet Azure CNI each pod reserves a VNet IP — size the
  // worker subnet accordingly (default /17 leaves ample headroom).
  default_max_pods = 100

  // Default system node pool (becomes the AKS default_node_pool).
  default_system_pool = {
    vmSize       = "Standard_D4s_v5"
    osDiskType   = "Managed"
    osDiskSizeGb = 128
    autoscaling = {
      enabled  = true
      minNodes = 1
      maxNodes = 3
    }
    labels = {}
  }

  system_pool = try(local.config.compute.aks.nodePools.system, local.default_system_pool)

  // Normalize worker node pools, keyed by name.
  // AKS node pool names: lowercase alphanumeric, 1-12 chars, must start with a letter.
  worker_pools = {
    for worker in try(local.config.compute.aks.nodePools.workers, []) :
    worker.name => {
      name         = substr(lower(replace(worker.name, "/[^a-z0-9]/", "")), 0, 12)
      vm_size      = try(worker.vmSize, try(worker.gpuType, null) != null ? local.gpu_default_vm_size : "Standard_D8s_v5")
      os_disk_type = try(worker.osDiskType, "Managed")
      os_disk_size = try(worker.osDiskSizeGb, 128)
      max_pods     = try(worker.maxPods, local.default_max_pods)
      is_gpu       = try(worker.gpuType, null) != null
      // Azure-managed NVIDIA driver install is opt-in; default assumes the
      // driver is provided in-cluster (e.g. NVIDIA GPU Operator).
      gpu_driver_install = try(worker.gpuDriverInstall, false)
      auto_scaling       = try(worker.autoscaling.enabled, true)
      min_nodes          = try(worker.autoscaling.minNodes, 1)
      max_nodes          = try(worker.autoscaling.maxNodes, 3)
      node_count         = try(worker.size, try(worker.autoscaling.minNodes, 1))
      labels             = try(worker.labels, {})
      config_taints      = try(worker.taints, [])
    }
  }

  // API server authorized IP ranges: config-provided networks + caller egress
  // IP + the cluster's own egress IP (NAT gateway public IP). The last one is
  // required on public clusters: nodes reach the API server via its PUBLIC
  // endpoint, egressing through the NAT gateway — omitting it fails cluster
  // creation with VMExtensionError_K8SAPIServerConnFail (live-validated).
  // Only applied when the cluster is public (see private_cluster_enabled note).
  authorized_ip_ranges = concat(
    [for net in try(local.config.cluster.aks.controlPlane.authorizedNetworks, []) : net.cidr],
    [local.egress_cidr],
    local.nat_enabled ? ["${azurerm_public_ip.nat[0].ip_address}/32"] : []
  )
}

// =====================================================================================
// Validation
// =====================================================================================

// Subscription validation is enforced via a lifecycle precondition on
// azurerm_virtual_network.main (see network.tf) to halt execution on mismatch,
// matching the EKS/GKE pattern.
