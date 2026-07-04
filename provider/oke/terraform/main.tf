// =====================================================================================
// Data sources
// =====================================================================================

// Resolves the configured tenancy OCID. OCI has no clean "caller identity"
// data source, so we assert the configured tenancy resolves and matches via a
// lifecycle precondition on oci_core_vcn.main (see network.tf).
data "oci_identity_tenancy" "this" {
  tenancy_id = local.tenancy
}

// Availability domains are a tenancy-level concept; query at the root (tenancy).
data "oci_identity_availability_domains" "this" {
  compartment_id = local.tenancy
}

// OCI service definitions (used by the service gateway to reach Object Storage
// and other OCI services over the private backbone).
data "oci_core_services" "all" {}

// OKE node image sources for the target Kubernetes version. Used to pick a
// compatible OKE worker image OCID for CPU and GPU node pools.
data "oci_containerengine_node_pool_option" "images" {
  node_pool_option_id = "all"
  compartment_id      = local.compartment
}

// Caller egress IP — appended to the API server allowed CIDRs so the executor
// can reach the (private-by-default) control-plane endpoint.
data "http" "egress_ip" {
  url             = "https://api.ipify.org"
  request_headers = { Accept = "text/plain" }
}

// =====================================================================================
// Configuration and derived locals
// =====================================================================================

locals {
  // Load configuration from YAML file
  config = yamldecode(file(var.CONFIG_PATH))

  config_dir       = dirname(var.CONFIG_PATH)
  config_filename  = basename(var.CONFIG_PATH)
  config_basename  = replace(local.config_filename, "/\\.ya?ml$/", "")
  status_file_path = "${local.config_dir}/${local.config_basename}-status.json"

  // Update time (lowercase letters, digits, underscores, dashes only)
  update_time = formatdate("YYYYMMDD-HHmmss", timestamp())

  // Required deployment settings.
  // deployment.tenancy -> OCI tenancy OCID; deployment.id -> resource prefix;
  // deployment.location -> OCI region identifier.
  prefix  = local.config.deployment.id
  tenancy = local.config.deployment.tenancy
  region  = local.config.deployment.location

  // compartmentId defaults to the tenancy (root compartment) when unset.
  compartment = try(local.config.cluster.oke.compartmentId, local.tenancy)

  // Freeform tags applied to every taggable resource.
  tags = try(local.config.deployment.tags, {})

  // Cluster settings.
  cluster_name = try(local.config.cluster.oke.name, local.prefix)
  oke_version  = local.config.cluster.oke.version

  // Control-plane exposure (private by default).
  is_public_ip_enabled = try(local.config.cluster.oke.controlPlane.isPublicIpEnabled, false)
  egress_cidr          = "${trimspace(data.http.egress_ip.response_body)}/32"

  // API server allowed CIDRs: config-provided list plus the caller egress /32.
  allowed_cidrs = distinct(concat(
    try(local.config.cluster.oke.controlPlane.allowedCidrs, []),
    [local.egress_cidr],
  ))

  // Network CIDRs.
  vcn_cidr      = try(local.config.network.oke.cidr, "10.0.0.0/16")
  pods_cidr     = try(local.config.network.oke.podsCidr, "10.244.0.0/16")
  services_cidr = try(local.config.network.oke.servicesCidr, "10.96.0.0/16")

  // Subnet CIDRs derived from the VCN CIDR (try() honors config overrides).
  // Layout (defaults for 10.0.0.0/16), non-overlapping:
  //   control-plane endpoint : 10.0.4.0/28   (regional, dedicated)
  //   system nodes           : 10.0.0.0/22
  //   service load balancers : 10.0.8.0/22
  //   pods (OCI_VCN_IP_NATIVE): 10.0.64.0/18
  //   worker nodes           : 10.0.128.0/17
  cp_subnet_cidr     = cidrsubnet(local.vcn_cidr, 12, 64) // 10.0.4.0/28
  system_subnet_cidr = try(local.config.network.oke.subnets.system.cidr, cidrsubnet(local.vcn_cidr, 6, 0))
  lb_subnet_cidr     = cidrsubnet(local.vcn_cidr, 6, 2) // 10.0.8.0/22
  pod_subnet_cidr    = cidrsubnet(local.vcn_cidr, 2, 1) // 10.0.64.0/18
  worker_subnet_cidr = try(local.config.network.oke.subnets.worker.cidr, cidrsubnet(local.vcn_cidr, 1, 1))

  // OKE node image selection. Sources are (image_id, source_name, source_type)
  // tuples for the cluster/version. Prefer an Oracle Linux non-GPU image for
  // CPU pools and a GPU-tagged image for GPU pools; fall back to first source.
  oke_image_sources = try(data.oci_containerengine_node_pool_option.images.sources, [])

  default_node_image_id = try(
    [for s in local.oke_image_sources : s.image_id
    if can(regex("Oracle-Linux", s.source_name)) && !can(regex("GPU", s.source_name))][0],
    try(local.oke_image_sources[0].image_id, null)
  )

  gpu_node_image_id = try(
    [for s in local.oke_image_sources : s.image_id if can(regex("GPU", s.source_name))][0],
    local.default_node_image_id
  )

  // Default system node pool (used when compute.oke.nodePools.system is unset).
  default_system_pool = {
    shape    = "VM.Standard.E4.Flex"
    ocpus    = 4
    memoryGb = 32
    size     = 3
  }

  system_pool_config = try(local.config.compute.oke.nodePools.system, local.default_system_pool)

  // Flatten node pools: system object + workers array, each tagged with type.
  all_node_pools = concat(
    [
      merge(
        local.system_pool_config,
        {
          name = "system"
          type = "system"
        }
      )
    ],
    [
      for worker in try(local.config.compute.oke.nodePools.workers, []) :
      merge(
        worker,
        {
          type = "worker"
        }
      )
    ]
  )

  // Normalized node pool map keyed by name, with resolved shape/image/labels.
  // GPU pools (gpuType set) assume NVIDIA H100 on shape BM.GPU.H100.8 and a
  // GPU-tagged OKE image; see compute.tf for details.
  node_pools = {
    for np in local.all_node_pools : np.name => {
      name             = np.name
      type             = np.type
      shape            = try(np.gpuType, null) != null ? try(np.shape, "BM.GPU.H100.8") : try(np.shape, "VM.Standard.E4.Flex")
      ocpus            = try(np.ocpus, 4)
      memoryGb         = try(np.memoryGb, 32)
      bootVolumeSizeGb = try(np.bootVolumeSizeGb, 100)
      size             = try(np.size, 1)
      gpuType          = try(np.gpuType, null)
      image_id         = try(np.gpuType, null) != null ? local.gpu_node_image_id : local.default_node_image_id
      // BM/GPU bare-metal shapes are fixed-size and reject node_shape_config.
      is_flex_shape = can(regex("Flex$", (try(np.gpuType, null) != null ? try(np.shape, "BM.GPU.H100.8") : try(np.shape, "VM.Standard.E4.Flex"))))
      labels        = try(np.labels, {})
    }
  }
}

// =====================================================================================
// Validation
// =====================================================================================

// Tenancy validation is enforced via a lifecycle precondition on
// oci_core_vcn.main (see network.tf) to halt execution on mismatch, matching
// the EKS/GKE pattern.
