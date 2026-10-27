// =====================================================================================
// Node Pools (system + workers)
// =====================================================================================

// One OKE managed node pool per entry in local.managed_pools (system object +
// workers without gpuMemoryFabricId; see fabric pools below for those).
//
// Autoscaling note: OKE does not expose node-pool autoscaling as a Terraform
// field. The desired node count is set via node_config_details.size; horizontal
// autoscaling is provided by the Kubernetes cluster-autoscaler add-on deployed
// in-cluster (out of scope for this module).
//
// GPU note: gpuType maps to a shape (local.gpu_shapes). x86 GPU shapes get the
// newest OKE GPU platform image; aarch64 GPU shapes (GB200/GB300) have no OKE
// platform image and require an explicit imageId.
resource "oci_containerengine_node_pool" "pools" {
  for_each = local.managed_pools

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

    // Spread across the pool's ADs (all by default; GPU capacity is usually
    // AD-specific, so GPU pools should pin availabilityDomains).
    dynamic "placement_configs" {
      for_each = toset(each.value.availability_domains)
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

  // Custom images get an explicit bootstrap; platform images keep OKE's default.
  node_metadata = each.value.image_override != null ? {
    user_data = base64encode(file("${path.module}/templates/custom-image-init.sh"))
  } : null

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

  lifecycle {
    precondition {
      condition     = each.value.shape != null
      error_message = "Node pool ${each.key}: unknown gpuType '${coalesce(each.value.gpuType, "-")}' (want one of: ${join(", ", keys(local.gpu_shapes))}), or set shape explicitly."
    }
    precondition {
      condition     = each.value.shape == null || each.value.shape_offered
      error_message = "Node pool ${each.key}: OKE does not offer ${coalesce(each.value.shape, "-")} for managed node pools in ${local.region} (provider/oke/tools/disco lists offered shapes)."
    }
    precondition {
      condition     = !(each.value.is_gpu && local.gpu_driver == "operator" && each.value.image_override == null)
      error_message = "Node pool ${each.key}: gpuDriver: operator needs a driverless Ubuntu imageId (the GPU Operator does not support the Oracle Linux platform images)."
    }
    precondition {
      condition     = each.value.image_id != null
      error_message = "Node pool ${each.key}: no OKE platform image for ${coalesce(each.value.shape, "-")} (${each.value.os_arch}, gpu=${each.value.is_gpu}) on ${local.oke_version}; set imageId."
    }
    precondition {
      condition     = length(each.value.availability_domains) > 0
      error_message = "Node pool ${each.key}: availabilityDomains ${jsonencode(each.value.ad_numbers)} match no AD in ${local.region}."
    }
  }

  // Bare-metal GPU shapes take well over 30m to provision and join.
  timeouts {
    create = "60m"
    update = "60m"
    delete = "45m"
  }
}

// =====================================================================================
// Fabric pools (self-managed nodes in a GPU memory fabric)
// =====================================================================================
//
// GB200/GB300 NVL72 hosts belong to a GPU memory fabric and are only reachable
// through a GPU memory cluster, which OKE managed node pools cannot express.
// Workers with gpuMemoryFabricId are therefore self-managed: a compute cluster
// and instance configuration feed a GPU memory cluster, whose instances join
// the (enhanced) cluster via oke-init using the metadata below.

locals {
  managed_pools = { for k, np in local.node_pools : k => np if np.gpu_memory_fabric_id == null }
  fabric_pools  = { for k, np in local.node_pools : k => np if np.gpu_memory_fabric_id != null }

  // Join metadata: private API endpoint host (no port) and cluster CA.
  apiserver_host  = try(split(":", oci_containerengine_cluster.main.endpoints[0].private_endpoint)[0], null)
  cluster_ca_cert = length(local.fabric_pools) > 0 ? yamldecode(data.oci_containerengine_cluster_kube_config.main[0].content).clusters[0].cluster["certificate-authority-data"] : null
}

data "oci_containerengine_cluster_kube_config" "main" {
  count = length(local.fabric_pools) > 0 ? 1 : 0

  cluster_id = oci_containerengine_cluster.main.id
}

// Self-managed nodes may join only this cluster, and only as instances in the
// deployment compartment. Lives in the deployment compartment, so it needs
// tenancy-level policy rights only when compartmentId is unset (root).
resource "oci_identity_policy" "cluster_join" {
  count    = length(local.fabric_pools) > 0 ? 1 : 0
  provider = oci.home

  compartment_id = local.compartment
  name           = "${local.iam_prefix}-oke-cluster-join"
  description    = "Allow self-managed nodes to join ${local.cluster_name}"
  freeform_tags  = local.tags

  statements = [
    "Allow any-user to {CLUSTER_JOIN} in ${local.policy_scope} where ALL {request.principal.type = 'instance', request.principal.compartment.id = '${local.compartment}', target.cluster.id = '${oci_containerengine_cluster.main.id}'}",
  ]
}

resource "time_sleep" "cluster_join_policy" {
  count = length(local.fabric_pools) > 0 ? 1 : 0

  create_duration = "60s"
  triggers = {
    statements = join("\n", oci_identity_policy.cluster_join[0].statements)
  }
}

resource "oci_core_compute_cluster" "fabric" {
  for_each = local.fabric_pools

  availability_domain = each.value.availability_domains[0]
  compartment_id      = local.compartment
  display_name        = "${local.prefix}-${each.key}"
  freeform_tags       = local.tags
}

resource "oci_core_instance_configuration" "fabric" {
  for_each = local.fabric_pools

  compartment_id = local.compartment
  display_name   = "${local.prefix}-${each.key}"
  freeform_tags  = local.tags

  instance_details {
    instance_type = "compute"

    launch_details {
      availability_domain = each.value.availability_domains[0]
      compartment_id      = local.compartment
      shape               = each.value.shape
      display_name        = "${local.prefix}-${each.key}"
      freeform_tags       = local.tags

      create_vnic_details {
        subnet_id                 = oci_core_subnet.worker.id
        nsg_ids                   = [oci_core_network_security_group.nodes.id]
        assign_public_ip          = false
        assign_private_dns_record = true
      }

      source_details {
        source_type             = "image"
        image_id                = each.value.image_id
        boot_volume_size_in_gbs = each.value.bootVolumeSizeGb
      }

      metadata = {
        user_data               = base64encode(file("${path.module}/templates/custom-image-init.sh"))
        oke-initial-node-labels = join(",", [for k, v in each.value.labels : "${k}=${v}"])

        // VCN-native pod networking for self-managed nodes.
        oke-native-pod-networking = "true"
        pod-subnets               = oci_core_subnet.pod.id
        pod-nsgids                = oci_core_network_security_group.pods.id
      }

      extended_metadata = {
        apiserver_host           = local.apiserver_host
        cluster_ca_cert          = local.cluster_ca_cert
        oke-k8version            = local.oke_version
        oke-kubeproxy-proxy-mode = "iptables"
        oke-tenancy-id           = local.tenancy
      }

      // RDMA plugins configure and authenticate the fabric NICs.
      agent_config {
        dynamic "plugins_config" {
          for_each = ["Compute HPC RDMA Authentication", "Compute HPC RDMA Auto-Configuration", "Compute RDMA GPU Monitoring"]
          content {
            name          = plugins_config.value
            desired_state = "ENABLED"
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = each.value.shape != null && each.value.image_id != null
      error_message = "Fabric pool ${each.key}: needs a resolvable shape (gpuType/shape) and imageId."
    }
    precondition {
      condition     = length(each.value.availability_domains) == 1
      error_message = "Fabric pool ${each.key}: a GPU memory cluster lives in one AD; pin availabilityDomains to the fabric's AD."
    }

    // Instance configurations are immutable and the GPU memory cluster
    // references this one; the replacement must exist before the old one is
    // deleted. Hosts already launched keep their image until the memory
    // cluster is recreated.
    create_before_destroy = true
  }
}

resource "oci_core_compute_gpu_memory_cluster" "fabric" {
  for_each = local.fabric_pools

  availability_domain       = each.value.availability_domains[0]
  compartment_id            = local.compartment
  compute_cluster_id        = oci_core_compute_cluster.fabric[each.key].id
  instance_configuration_id = oci_core_instance_configuration.fabric[each.key].id
  gpu_memory_fabric_id      = each.value.gpu_memory_fabric_id
  size                      = tostring(each.value.size)
  display_name              = "${local.prefix}-${each.key}"
  freeform_tags             = local.tags

  depends_on = [time_sleep.cluster_join_policy]

  // Hosts take their cluster binding (API endpoint, CA) only at launch, so a
  // replaced cluster must relaunch them; an instance configuration change
  // alone does not.
  lifecycle {
    replace_triggered_by = [oci_containerengine_cluster.main.id]
  }

  timeouts {
    create = "60m"
    update = "60m"
    delete = "45m"
  }
}
