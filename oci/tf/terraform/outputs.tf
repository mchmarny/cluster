# =====================================================================================
# Status to standard output
# =====================================================================================

output "status" {
  description = "Deployment"
  value = {
    deployment = {
      tenancyId     = local.tenancy_ocid
      compartmentId = local.compartment_ocid
      region        = local.region
      updated       = local.updateTime
      prefix        = local.prefix
      tags          = try(local.config.deployment.tags, {})
      statusFile    = local.statusFilePath
    }
    access = {
      command     = "oci ce cluster create-kubeconfig --cluster-id ${oci_containerengine_cluster.main.id} --region ${local.region} --file ${local_sensitive_file.kubeconfig.filename}"
      kubecofnig  = local_sensitive_file.kubeconfig.filename
      description = "Use the command above or export KUBECONFIG=${local_sensitive_file.kubeconfig.filename}"
    }
  }
}

# =====================================================================================
# Status to JSON file (next to config file)
# =====================================================================================
locals {
  status_data = {
    apiVersion = "github.com/mchmarny/cluster/v1alpha1"
    kind       = "ClusterStatus"
    metadata = {
      name      = oci_containerengine_cluster.main.name
      timestamp = local.updateTime
    }
    deployment = {
      id            = local.prefix
      tenancyId     = local.tenancy_ocid
      compartmentId = local.compartment_ocid
      region        = local.region
      tags          = try(local.config.deployment.tags, {})
    }
    cluster = {
      name    = oci_containerengine_cluster.main.name
      id      = oci_containerengine_cluster.main.id
      version = oci_containerengine_cluster.main.kubernetes_version
      state   = oci_containerengine_cluster.main.state
      kubernetes = {
        endpoint    = oci_containerengine_cluster.main.endpoints[0].private_endpoint
        podsCidr    = local.pod_cidr
        svcscidr    = local.service_cidr
        cniType     = oci_containerengine_cluster.main.cluster_pod_network_options[0].cni_type
        clusterType = try(oci_containerengine_cluster.main.type, "BASIC_CLUSTER")
      }
      addons = {
        for addon_name, addon_enabled in {
          clusterAutoscaler   = length(oci_containerengine_addon.cluster_autoscaler) > 0
          kubernetesDashboard = length(oci_containerengine_addon.kubernetes_dashboard) > 0
          certManager         = length(oci_containerengine_addon.cert_manager) > 0
          } : addon_name => {
          name    = addon_name
          enabled = addon_enabled
        } if addon_enabled
      }
    }
    network = {
      vcn = {
        id   = oci_core_vcn.main.id
        cidr = local.vcn_cidr
      }
      subnets = {
        public = [
          for k, v in oci_core_subnet.public : {
            name = "public${k}"
            id   = v.id
            cidr = v.cidr_block
            ad   = try(v.availability_domain, "regional")
          }
        ]
        apiEndpoint = [
          for k, v in oci_core_subnet.api_endpoint : {
            name = "apiEndpoint${k}"
            id   = v.id
            cidr = v.cidr_block
            ad   = try(v.availability_domain, "regional")
          }
        ]
        nodePools = [
          for k, v in oci_core_subnet.node_pools : {
            name = "nodePools${k}"
            id   = v.id
            cidr = v.cidr_block
            ad   = try(v.availability_domain, "regional")
          }
        ]
        pods = [
          for k, v in oci_core_subnet.pods : {
            name = "pods${k}"
            id   = v.id
            cidr = v.cidr_block
            ad   = try(v.availability_domain, "regional")
          }
        ]
        storage = [
          for i, v in oci_core_subnet.storage : {
            name = "storage${i}"
            id   = v.id
            cidr = v.cidr_block
            ad   = try(v.availability_domain, "regional")
          }
        ]
      }
      securityGroups = {
        controlPlane  = oci_core_network_security_group.control_plane.id
        loadBalancers = oci_core_network_security_group.load_balancers.id
        nodes         = oci_core_network_security_group.nodes.id
        pods          = oci_core_network_security_group.pods.id
        storage       = oci_core_network_security_group.storage.id
      }
      gateways = {
        internet = oci_core_internet_gateway.main.id
        nat      = oci_core_nat_gateway.main.id
        service  = oci_core_service_gateway.main.id
      }
    }
    compute = {
      nodePools = [
        for k, v in oci_containerengine_node_pool.pools : {
          name              = v.name
          id                = v.id
          type              = try(local.node_pools[k].type, "worker")
          kubernetesVersion = v.kubernetes_version
          nodeShape         = v.node_shape
          ocpus             = try(v.node_shape_config[0].ocpus, null)
          memoryGb          = try(v.node_shape_config[0].memory_in_gbs, null)
          size              = v.node_config_details[0].size
          maxPodsPerNode    = try(v.node_config_details[0].node_pool_pod_network_option_details[0].max_pods_per_node, null)
          autoscaling = try({
            enabled = local.node_pools[k].autoscaling.enabled
            min     = local.node_pools[k].autoscaling.minSize
            max     = local.node_pools[k].autoscaling.maxSize
          }, null)
        }
      ]
    }
    iam = {
      dynamicGroups = {
        nodePools = oci_identity_dynamic_group.node_pools.id
      }
      policies = {
        nodePools         = oci_identity_policy.node_pools.id
        clusterAutoscaler = length(oci_identity_policy.cluster_autoscaler) > 0 ? oci_identity_policy.cluster_autoscaler[0].id : null
        fssWorkload       = oci_identity_policy.fss_workload.id
        clusterWorkload   = oci_identity_policy.cluster_workload.id
        secretsWorkload   = length(oci_identity_policy.secrets_workload) > 0 ? oci_identity_policy.secrets_workload[0].id : null
      }
      tagNamespace = {
        id   = oci_identity_tag_namespace.cluster.id
        name = oci_identity_tag_namespace.cluster.name
      }
    }
    security = {
      kubeconfig = {
        path = local_sensitive_file.kubeconfig.filename
      }
    }
  }
}

// Write status to JSON file
resource "local_file" "status" {
  filename = local.statusFilePath
  content  = jsonencode(local.status_data)

  file_permission      = "0644"
  directory_permission = "0755"
}
