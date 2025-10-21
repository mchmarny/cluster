# Node Pools
resource "oci_containerengine_node_pool" "pools" {
  for_each = local.node_pools

  cluster_id         = oci_containerengine_cluster.main.id
  compartment_id     = local.compartment_ocid
  name               = "${local.prefix}-${each.key}"
  kubernetes_version = local.oke_version

  node_config_details {
    size = try(each.value.size, 3)

    dynamic "placement_configs" {
      for_each = local.availability_domains
      content {
        availability_domain = placement_configs.value.name
        subnet_id           = values(oci_core_subnet.node_pools)[0].id

        capacity_reservation_id = try(each.value.capacityReservation, null)
      }
    }

    freeform_tags = merge(
      local.freeform_tags,
      {
        "node-pool" = each.key
        "node-type" = try(each.value.type, "worker")
      }
    )

    is_pv_encryption_in_transit_enabled = true

    node_pool_pod_network_option_details {
      cni_type          = "OCI_VCN_IP_NATIVE"
      max_pods_per_node = try(each.value.maxPodsPerNode, 31)
      pod_subnet_ids    = [for s in oci_core_subnet.pods : s.id]
    }
  }

  node_shape = try(each.value.shape, "VM.Standard.E5.Flex")

  node_shape_config {
    memory_in_gbs = try(each.value.memoryGb, 16)
    ocpus         = try(each.value.ocpus, 2)
  }

  node_source_details {
    image_id    = try(each.value.imageId, data.oci_core_images.node_images[each.key].images[0].id)
    source_type = "IMAGE"

    boot_volume_size_in_gbs = try(each.value.diskSizeGb, 100)
  }

  initial_node_labels {
    key   = "node-pool"
    value = each.key
  }

  initial_node_labels {
    key   = "node-type"
    value = try(each.value.type, "worker")
  }

  ssh_public_key = local.ssh_public_key

  freeform_tags = local.freeform_tags

  lifecycle {
    ignore_changes = [
      node_source_details[0].image_id,
      kubernetes_version,
    ]
  }
}

# Get the latest OKE node images
data "oci_core_images" "node_images" {
  for_each = local.node_pools

  compartment_id           = local.compartment_ocid
  operating_system         = "Oracle Linux"
  operating_system_version = "8"
  shape                    = try(each.value.shape, "VM.Standard.E5.Flex")
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"

  filter {
    name   = "display_name"
    values = ["^Oracle-Linux-.*-OKE-${local.oke_version}.*"]
    regex  = true
  }
}

# Autoscaling configuration
resource "oci_autoscaling_auto_scaling_configuration" "node_pool_autoscaler" {
  for_each = {
    for k, v in local.node_pools : k => v
    if try(v.autoscaling.enabled, false)
  }

  compartment_id = local.compartment_ocid
  display_name   = "${local.prefix}-${each.key}-autoscaler"
  auto_scaling_resources {
    id   = oci_containerengine_node_pool.pools[each.key].id
    type = "nodePool"
  }

  policies {
    display_name = "${local.prefix}-${each.key}-autoscale-policy"
    policy_type  = "threshold"

    capacity {
      initial = try(each.value.size, 3)
      max     = try(each.value.autoscaling.maxSize, 10)
      min     = try(each.value.autoscaling.minSize, 1)
    }

    rules {
      action {
        type  = "CHANGE_COUNT_BY"
        value = 1
      }

      display_name = "Scale Out"

      metric {
        metric_type = "CPU_UTILIZATION"

        threshold {
          operator = "GT"
          value    = try(each.value.autoscaling.targetCpuPercent, 70)
        }
      }
    }

    rules {
      action {
        type  = "CHANGE_COUNT_BY"
        value = -1
      }

      display_name = "Scale In"

      metric {
        metric_type = "CPU_UTILIZATION"

        threshold {
          operator = "LT"
          value    = try(each.value.autoscaling.targetCpuPercent, 70) - 20
        }
      }
    }
  }

  freeform_tags = local.freeform_tags
}
