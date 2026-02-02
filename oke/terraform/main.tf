data "oci_identity_availability_domains" "ads" {
  compartment_id = local.compartment_ocid
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
  updateTime = formatdate("YYYYMMDD-HHmmss", timestamp())

  // Extract required deployment settings
  prefix           = local.config.deployment.id
  tenancy_ocid     = local.config.deployment.tenancy
  compartment_ocid = local.config.deployment.oci.compartment
  region           = local.config.deployment.location
  egress_cidr      = "${trimspace(data.http.egress_ip.response_body)}/32"

  // Extract optional deployment settings with defaults
  oke_version  = try(local.config.cluster.version, "v1.33.1")
  cluster_name = try(local.config.cluster.name, "${local.prefix}-oke")

  // Network configuration with defaults
  vcn_cidr     = try(local.config.network.cidrs.host, "10.0.0.0/16")
  pod_cidr     = try(local.config.network.cidrs.pod, "100.65.0.0/16")
  service_cidr = try(local.config.cluster.controlPlane.cidr, "172.20.0.0/16")
  allowed_cidrs = concat(
    try(local.config.cluster.controlPlane.allowedCidrs, []),
    [local.egress_cidr]
  )

  // Default subnet CIDRs (auto-computed from VCN CIDR)
  default_subnets = {
    public      = [{ cidr = cidrsubnet(local.vcn_cidr, 11, 0) }, { cidr = cidrsubnet(local.vcn_cidr, 11, 1) }]  // 10.0.0.0/27, 10.0.0.32/27
    apiEndpoint = [{ cidr = cidrsubnet(local.vcn_cidr, 12, 6) }]                                                // 10.0.0.96/28
    nodePools   = [{ cidr = cidrsubnet(local.vcn_cidr, 6, 1) }, { cidr = cidrsubnet(local.vcn_cidr, 6, 2) }]    // 10.0.4.0/22, 10.0.8.0/22
    pods        = [{ cidr = cidrsubnet(local.pod_cidr, 2, 0) }, { cidr = cidrsubnet(local.pod_cidr, 2, 1) }]    // 100.65.0.0/18, 100.65.64.0/18
  }

  // Use config subnets or defaults
  subnets_public      = try(local.config.network.subnets.public, local.default_subnets.public)
  subnets_api         = try(local.config.network.subnets.apiEndpoint, local.default_subnets.apiEndpoint)
  subnets_nodes       = try(local.config.network.subnets.nodePools, local.default_subnets.nodePools)
  subnets_pods        = try(local.config.network.subnets.pods, local.default_subnets.pods)

  // Availability domains
  availability_domains = data.oci_identity_availability_domains.ads.availability_domains

  // Tags
  freeform_tags = merge(
    try(local.config.deployment.tags, {}),
    {
      "deployment-id" = local.prefix
      "managed-by"    = "terraform"
      "last-updated"  = local.updateTime
    }
  )

  // Default node pool configuration
  default_node_pools = {
    system = {
      type          = "system"
      shape         = "VM.Standard.E5.Flex"
      ocpus         = 2
      memoryGb      = 16
      diskSizeGb    = 100
      size          = 3
      maxPodsPerNode = 31
      autoscaling = {
        enabled          = true
        minSize          = 2
        maxSize          = 10
        targetCpuPercent = 70
      }
    }
  }

  // Node pool configuration (use config or defaults)
  node_pools = length(try(local.config.compute.nodePools, {})) > 0 ? local.config.compute.nodePools : local.default_node_pools

  // SSH public key
  ssh_public_key = try(local.config.compute.sshPublicKey, null)
}
