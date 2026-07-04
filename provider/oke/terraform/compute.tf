// =====================================================================================
// Node Pools (system + workers)
// =====================================================================================

// One node pool per entry in local.node_pools (system object + workers array).
//
// Autoscaling note: OKE does not expose node-pool autoscaling as a Terraform
// field. The desired node count is set via node_config_details.size; horizontal
// autoscaling is provided by the Kubernetes cluster-autoscaler add-on deployed
// in-cluster (out of scope for this module).
//
// GPU note: when a pool sets gpuType, the module assumes NVIDIA H100 on the
// bare-metal shape BM.GPU.H100.8 (fixed-size; no node_shape_config) and selects
// a GPU-tagged OKE image. Adjust shape/image for other accelerators.
resource "oci_containerengine_node_pool" "pools" {
  for_each = local.node_pools

  cluster_id         = oci_containerengine_cluster.main.id
  compartment_id     = local.compartment
  name               = "${local.prefix}-${each.key}"
  kubernetes_version = local.oke_version
  node_shape         = each.value.shape
  freeform_tags      = local.tags

  // Flex shapes require an explicit OCPU/memory config; fixed BM/GPU shapes
  // reject it, so emit the block only for *.Flex shapes.
  dynamic "node_shape_config" {
    for_each = each.value.is_flex_shape ? [1] : []
    content {
      ocpus         = each.value.ocpus
      memory_in_gbs = each.value.memoryGb
    }
  }

  node_config_details {
    size = each.value.size

    // Spread nodes across all availability domains in the region.
    dynamic "placement_configs" {
      for_each = {
        for idx, ad in data.oci_identity_availability_domains.this.availability_domains :
        idx => ad.name
      }
      content {
        availability_domain = placement_configs.value
        subnet_id           = each.value.type == "system" ? oci_core_subnet.system.id : oci_core_subnet.worker.id
      }
    }

    nsg_ids = [oci_core_network_security_group.nodes.id]

    // Native pod networking — pods get VCN IPs from the dedicated pod subnet.
    node_pool_pod_network_option_details {
      cni_type       = "OCI_VCN_IP_NATIVE"
      pod_subnet_ids = [oci_core_subnet.pod.id]
      pod_nsg_ids    = [oci_core_network_security_group.pods.id]
    }
  }

  // OKE platform image selected for the target Kubernetes version.
  node_source_details {
    source_type             = "IMAGE"
    image_id                = each.value.image_id
    boot_volume_size_in_gbs = each.value.bootVolumeSizeGb
  }

  // Node labels from config.
  dynamic "initial_node_labels" {
    for_each = each.value.labels
    content {
      key   = initial_node_labels.key
      value = initial_node_labels.value
    }
  }

  timeouts {
    create = "30m"
    update = "30m"
    delete = "30m"
  }
}
