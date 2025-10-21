# Dynamic Group for Node Pools
resource "oci_identity_dynamic_group" "node_pools" {
  compartment_id = local.tenancy_ocid
  name           = "${local.prefix}-node-pools-dg"
  description    = "Dynamic group for OKE node pools in ${local.prefix}"

  matching_rule = "ALL {instance.compartment.id = '${local.compartment_ocid}', tag.${oci_identity_tag_namespace.cluster.name}.${oci_identity_tag.cluster_id.name}.value = '${oci_containerengine_cluster.main.id}'}"

  freeform_tags = local.freeform_tags
}

# Tag Namespace for Cluster
resource "oci_identity_tag_namespace" "cluster" {
  compartment_id = local.compartment_ocid
  name           = "${local.prefix}-oke-tags"
  description    = "Tag namespace for OKE cluster ${local.prefix}"

  freeform_tags = local.freeform_tags
}

# Tag for Cluster ID
resource "oci_identity_tag" "cluster_id" {
  tag_namespace_id = oci_identity_tag_namespace.cluster.id
  name             = "cluster-id"
  description      = "OKE Cluster ID"

  freeform_tags = local.freeform_tags
}

# Policies for Node Pools
resource "oci_identity_policy" "node_pools" {
  compartment_id = local.compartment_ocid
  name           = "${local.prefix}-node-pools-policy"
  description    = "Policy for OKE node pools in ${local.prefix}"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.node_pools.name} to read instance-family in compartment id ${local.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.node_pools.name} to use vnics in compartment id ${local.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.node_pools.name} to use subnets in compartment id ${local.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.node_pools.name} to use network-security-groups in compartment id ${local.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.node_pools.name} to use private-ips in compartment id ${local.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.node_pools.name} to manage load-balancers in compartment id ${local.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.node_pools.name} to manage volumes in compartment id ${local.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.node_pools.name} to manage file-systems in compartment id ${local.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.node_pools.name} to manage object-family in compartment id ${local.compartment_ocid}",
  ]

  freeform_tags = local.freeform_tags
}

# Policy for Cluster Autoscaler
resource "oci_identity_policy" "cluster_autoscaler" {
  count = try(local.config.cluster.addons.clusterAutoscaler, false) ? 1 : 0

  compartment_id = local.compartment_ocid
  name           = "${local.prefix}-cluster-autoscaler-policy"
  description    = "Policy for Cluster Autoscaler in ${local.prefix}"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.node_pools.name} to manage cluster-node-pools in compartment id ${local.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.node_pools.name} to manage instance-family in compartment id ${local.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.node_pools.name} to use subnets in compartment id ${local.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.node_pools.name} to read virtual-network-family in compartment id ${local.compartment_ocid}",
    "Allow dynamic-group ${oci_identity_dynamic_group.node_pools.name} to use vnics in compartment id ${local.compartment_ocid}",
  ]

  freeform_tags = local.freeform_tags
}
