// =====================================================================================
// Identity: dynamic group + policy for OKE
// =====================================================================================
//
// Identity resources live in the tenancy (root compartment) and require
// root-tenancy manage permissions. When the executor lacks those permissions
// (e.g. deploying into a delegated compartment), set cluster.oke.identity.manage
// to false to skip creation and manage the dynamic group/policy out of band.

locals {
  manage_identity = try(local.config.cluster.oke.identity.manage, true)

  // Compartment referenced in identity matching/policy statements.
  identity_compartment_id = local.compartment
}

// Dynamic group matching all instances (nodes) in the target compartment.
resource "oci_identity_dynamic_group" "nodes" {
  count = local.manage_identity ? 1 : 0

  compartment_id = local.tenancy // dynamic groups must live in the tenancy
  name           = "${local.prefix}-oke-nodes"
  description    = "OKE worker node instances for ${local.cluster_name}"
  matching_rule  = "ALL {instance.compartment.id = '${local.identity_compartment_id}'}"
  freeform_tags  = local.tags
}

// Policy granting the node dynamic group the permissions OKE nodes need:
// use the VCN, and read Object Storage (e.g. images / state artifacts).
resource "oci_identity_policy" "nodes" {
  count = local.manage_identity ? 1 : 0

  compartment_id = local.tenancy
  name           = "${local.prefix}-oke-nodes-policy"
  description    = "OKE node permissions for ${local.cluster_name}"
  freeform_tags  = local.tags

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.nodes[0].name} to use virtual-network-family in compartment id ${local.identity_compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.nodes[0].name} to read object-family in compartment id ${local.identity_compartment_id}",
    "Allow dynamic-group ${oci_identity_dynamic_group.nodes[0].name} to use instance-family in compartment id ${local.identity_compartment_id}",
  ]
}
