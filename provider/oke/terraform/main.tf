// =====================================================================================
// Data sources
// =====================================================================================

// Resolves the configured tenancy OCID. OCI has no clean "caller identity"
// data source, so we assert the configured tenancy resolves and matches via a
// lifecycle precondition on oci_core_vcn.main (see network.tf).
data "oci_identity_tenancy" "this" {
  tenancy_id = local.tenancy
}

// Region key -> name, to resolve the tenancy's home region for IAM writes.
data "oci_identity_regions" "all" {}

// Availability domains are a tenancy-level concept; query at the root (tenancy).
data "oci_identity_availability_domains" "this" {
  compartment_id = local.tenancy
}

// "All <region> Services In Oracle Services Network" — matched by name because
// the API list order is not contractual.
data "oci_core_services" "all" {
  filter {
    name   = "name"
    values = ["All .* Services In Oracle Services Network"]
    regex  = true
  }
}

// OKE node pool options for the target Kubernetes version, one lookup per CPU
// architecture in use: platform images (sources) and the shapes OKE offers in
// the region, which vary by region.
data "oci_containerengine_node_pool_option" "images" {
  for_each = toset([for t in local.pool_traits : t.os_arch])

  node_pool_option_id   = "all"
  compartment_id        = local.compartment
  node_pool_k8s_version = local.oke_version
  node_pool_os_arch     = each.key
}

// Caller egress IP — appended to the API server allowed CIDRs so the executor
// can reach a public control-plane endpoint.
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

  home_region = one([
    for r in data.oci_identity_regions.all.regions : r.name
    if r.key == data.oci_identity_tenancy.this.home_region_key
  ])

  // compartmentId defaults to the tenancy (root compartment) when unset.
  compartment = try(local.config.cluster.oke.compartmentId, local.tenancy)

  // IAM policy scope: the root compartment is addressed as "tenancy".
  policy_scope = local.compartment == local.tenancy ? "tenancy" : "compartment id ${local.compartment}"

  // IAM names are tenancy-wide while state is per region; qualify them.
  iam_prefix = "${local.prefix}-${local.region}"

  // GPU driver source. "image": the node image ships the NVIDIA driver (OKE GPU
  // platform images, Oracle GPU images). "operator": driverless image; a GPU
  // Operator installed outside this module provides driver, toolkit, and device
  // plugin. The module deploys no GPU runtime components either way.
  gpu_driver = try(local.config.cluster.oke.gpuDriver, "image")

  // OKE's NvidiaGpuPlugin must not compete with a GPU Operator's device plugin.
  disable_oke_gpu_plugin = local.gpu_driver == "operator"

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

  // gpuType -> shape. Unknown types resolve to null and fail the node pool
  // precondition at plan time rather than silently landing on another shape.
  gpu_shapes = {
    a10   = "VM.GPU.A10.1"
    l40s  = "BM.GPU.L40S.4"
    h100  = "BM.GPU.H100.8"
    gb200 = "BM.GPU.GB200.4"
    gb300 = "BM.GPU.GB300.4"
  }

  // Default system node pool (used when compute.oke.nodePools.system is unset).
  default_system_pool = {
    shape    = "VM.Standard.E5.Flex"
    ocpus    = 4
    memoryGb = 32
    size     = 3
  }

  system_pool_config = try(local.config.compute.oke.nodePools.system, local.default_system_pool)

  // Flatten node pools: system object + workers array, each tagged with type.
  all_node_pools = concat(
    [merge(local.system_pool_config, { name = "system", type = "system" })],
    [for worker in try(local.config.compute.oke.nodePools.workers, []) : merge(worker, { type = "worker" })],
  )

  // Per-pool settings that do not depend on the image catalog.
  pool_specs = {
    for np in local.all_node_pools : np.name => merge(
      {
        name             = np.name
        type             = np.type
        gpuType          = try(lower(np.gpuType), null)
        ocpus            = try(np.ocpus, 4)
        memoryGb         = try(np.memoryGb, 32)
        bootVolumeSizeGb = try(np.bootVolumeSizeGb, 100)
        size             = try(np.size, np.type == "system" ? 3 : 1)
        labels           = try(np.labels, {})
        image_override   = try(np.imageId, null)
        // Self-managed pool in a GPU memory fabric (see compute.tf).
        gpu_memory_fabric_id = try(np.gpuMemoryFabricId, null)
        // AD numbers (1-based); empty means every AD in the region.
        ad_numbers = [for n in try(np.availabilityDomains, []) : tostring(n)]
      },
      {
        shape = try(np.shape, null) != null ? np.shape : (
          try(np.gpuType, null) != null ? lookup(local.gpu_shapes, lower(np.gpuType), null) : "VM.Standard.E5.Flex"
        )
      },
    )
  }

  // Shape-derived traits. Ampere (A*) and Grace (GB*) shapes are aarch64; GPU
  // shapes are NVIDIA ones (all VM/BM.GPU* families except AMD MI*).
  pool_traits = {
    for k, np in local.pool_specs : k => {
      os_arch       = can(regex("^(VM|BM)\\.Standard\\.A[0-9]|^BM\\.GPU\\.GB[0-9]", coalesce(np.shape, "-"))) ? "AARCH64" : "X86_64"
      is_gpu        = can(regex("^(VM|BM)\\.GPU", coalesce(np.shape, "-"))) && !can(regex("\\.MI[0-9]", coalesce(np.shape, "-")))
      is_flex_shape = can(regex("Flex$", coalesce(np.shape, "-")))
    }
  }

  // Newest platform image per (arch, gpu). Sort key leads with the build date
  // embedded in the source name (e.g. 2026.09.18-0) so selection is stable for
  // a given catalog; pin imageId per pool to freeze it across catalog updates.
  platform_images = {
    for arch, opt in data.oci_containerengine_node_pool_option.images : arch => {
      for gpu in [true, false] : tostring(gpu) => try(
        split("|", reverse(sort([
          for s in opt.sources :
          "${try(regex("\\d{4}\\.\\d{2}\\.\\d{2}-\\d+", s.source_name), "0000")}|${s.source_name}|${s.image_id}"
          if can(regex("-GPU-", s.source_name)) == gpu
        ]))[0]),
        null
      )
    }
  }

  // Normalized node pool map keyed by name, with resolved shape/image/ADs.
  node_pools = {
    for k, np in local.pool_specs : k => merge(np, local.pool_traits[k], {
      image_id = np.image_override != null ? np.image_override : try(
        local.platform_images[local.pool_traits[k].os_arch][tostring(local.pool_traits[k].is_gpu)][2], null
      )
      shape_offered = contains(
        try(data.oci_containerengine_node_pool_option.images[local.pool_traits[k].os_arch].shapes, []),
        coalesce(np.shape, "-"),
      )
      image_name = np.image_override != null ? null : try(
        local.platform_images[local.pool_traits[k].os_arch][tostring(local.pool_traits[k].is_gpu)][1], null
      )
      // Oracle's per-node switch for the NvidiaGpuPlugin add-on.
      labels = merge(np.labels, local.pool_traits[k].is_gpu && local.disable_oke_gpu_plugin ? {
        "oci.oraclecloud.com/disable-gpu-device-plugin" = "true"
      } : {})
      availability_domains = [
        for ad in data.oci_identity_availability_domains.this.availability_domains : ad.name
        if length(np.ad_numbers) == 0 || contains(np.ad_numbers, regex("[0-9]+$", ad.name))
      ]
    })
  }
}

// =====================================================================================
// Validation
// =====================================================================================

// Tenancy validation is enforced via a lifecycle precondition on
// oci_core_vcn.main (see network.tf) to halt execution on mismatch, matching
// the EKS/GKE pattern.
