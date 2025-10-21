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
  compartment_ocid = local.config.deployment.compartment
  region           = local.config.deployment.region
  egress_cidr      = "${trimspace(data.http.egress_ip.response_body)}/32"

  // Extract optional deployment settings with defaults
  oke_version  = try(local.config.cluster.version, "v1.33.1")
  cluster_name = try(local.config.cluster.name, "${local.prefix}-oke")

  // Network configuration
  vcn_cidr      = local.config.network.cidrs.host
  pod_cidr      = local.config.network.cidrs.pod
  service_cidr  = local.config.cluster.controlPlane.cidr
  allowed_cidrs = concat(local.config.cluster.controlPlane.allowedCidrs, [local.egress_cidr])

  // Availability domains
  availability_domains = data.oci_identity_availability_domains.ads.availability_domains

  // Tags
  freeform_tags = merge(
    local.config.deployment.tags,
    {
      "deployment-id" = local.prefix
      "managed-by"    = "terraform"
      "last-updated"  = local.updateTime
    }
  )

  // Node pool configuration
  node_pools = try(local.config.compute.nodePools, {})

  // SSH public key
  ssh_public_key = try(local.config.compute.sshPublicKey, null)
}
