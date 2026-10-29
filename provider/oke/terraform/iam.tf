// =====================================================================================
// Identity: dynamic group + policy for OKE
// =====================================================================================
//
// Identity resources live in the tenancy (root compartment) and require
// root-tenancy manage permissions, so creation is opt-in via
// cluster.oke.identity.manage. Managed node pools do not need them (with
// either CNI); they grant node instance principals read access
// to Object Storage for in-cluster workloads. The matching rule covers every
// instance in the compartment, which is broad in a shared compartment.

locals {
  manage_identity = try(local.config.cluster.oke.identity.manage, false)

  // Compartment referenced in identity matching/policy statements.
  identity_compartment_id = local.compartment
}

// Dynamic group matching all instances (nodes) in the target compartment.
resource "oci_identity_dynamic_group" "nodes" {
  count    = local.manage_identity ? 1 : 0
  provider = oci.home

  compartment_id = local.tenancy // dynamic groups must live in the tenancy
  name           = "${local.iam_prefix}-oke-nodes"
  description    = "OKE worker node instances for ${local.cluster_name}"
  matching_rule  = "ALL {instance.compartment.id = '${local.identity_compartment_id}'}"
  freeform_tags  = local.tags
}

// Policy granting the node dynamic group the permissions OKE nodes need:
// use the VCN, and read Object Storage (e.g. images / state artifacts).
resource "oci_identity_policy" "nodes" {
  count    = local.manage_identity ? 1 : 0
  provider = oci.home

  compartment_id = local.tenancy
  name           = "${local.iam_prefix}-oke-nodes-policy"
  description    = "OKE node permissions for ${local.cluster_name}"
  freeform_tags  = local.tags

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.nodes[0].name} to read object-family in ${local.policy_scope}",
  ]
}
