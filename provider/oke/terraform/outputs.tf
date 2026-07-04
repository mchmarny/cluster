// =====================================================================================
// Status to standard output
// =====================================================================================

output "status" {
  description = "Deployment"
  value = {
    deployment = {
      tenancy    = local.tenancy
      region     = local.region
      updated    = local.update_time
      prefix     = local.prefix
      tags       = local.tags
      statusFile = local.status_file_path
    }
    access = {
      command = "oci ce cluster create-kubeconfig --cluster-id ${oci_containerengine_cluster.main.id} --file $HOME/.kube/config --region ${local.region} --token-version 2.0.0 --kube-endpoint PRIVATE_ENDPOINT"
    }
  }
}

// =====================================================================================
// Status to JSON file (next to config file)
// =====================================================================================

locals {
  status_data = {
    apiVersion = "github.com/mchmarny/cluster/v1alpha1"
    kind       = "ClusterStatus"
    metadata = {
      name      = oci_containerengine_cluster.main.name
      timestamp = local.update_time
    }
    deployment = {
      id          = local.prefix
      tenancy     = local.tenancy
      compartment = local.compartment
      region      = local.region
      tags        = local.tags
    }
    cluster = {
      id      = oci_containerengine_cluster.main.id
      name    = oci_containerengine_cluster.main.name
      version = oci_containerengine_cluster.main.kubernetes_version
      type    = oci_containerengine_cluster.main.type
      kubernetes = {
        privateEndpoint = try(oci_containerengine_cluster.main.endpoints[0].private_endpoint, null)
        publicEndpoint  = try(oci_containerengine_cluster.main.endpoints[0].public_endpoint, null)
        podsCidr        = local.pods_cidr
        servicesCidr    = local.services_cidr
      }
      features = {
        etcdEncryption      = local.etcd_encryption_enabled
        privateControlPlane = !local.is_public_ip_enabled
      }
    }
    compute = {
      nodePools = [
        for name, np in local.node_pools : {
          name             = np.name
          type             = np.type
          shape            = np.shape
          ocpus            = np.is_flex_shape ? np.ocpus : null
          memoryGb         = np.is_flex_shape ? np.memoryGb : null
          bootVolumeSizeGb = np.bootVolumeSizeGb
          size             = np.size
          gpuType          = np.gpuType
          nodePoolId       = try(oci_containerengine_node_pool.pools[name].id, null)
        }
      ]
    }
    network = {
      vcn = {
        id   = oci_core_vcn.main.id
        name = oci_core_vcn.main.display_name
        cidr = local.vcn_cidr
      }
      subnets = {
        controlPlane = { id = oci_core_subnet.control_plane.id, cidr = oci_core_subnet.control_plane.cidr_block }
        system       = { id = oci_core_subnet.system.id, cidr = oci_core_subnet.system.cidr_block }
        worker       = { id = oci_core_subnet.worker.id, cidr = oci_core_subnet.worker.cidr_block }
        pod          = { id = oci_core_subnet.pod.id, cidr = oci_core_subnet.pod.cidr_block }
        lb           = { id = oci_core_subnet.lb.id, cidr = oci_core_subnet.lb.cidr_block }
      }
      gateways = {
        internet = oci_core_internet_gateway.main.id
        nat      = oci_core_nat_gateway.main.id
        service  = oci_core_service_gateway.main.id
      }
    }
    security = {
      kms = local.etcd_encryption_enabled ? {
        vaultId = oci_kms_vault.main[0].id
        keyId   = oci_kms_key.etcd[0].id
      } : null
      networkSecurityGroups = {
        controlPlane = oci_core_network_security_group.control_plane.id
        nodes        = oci_core_network_security_group.nodes.id
        pods         = oci_core_network_security_group.pods.id
      }
      dynamicGroup = local.manage_identity ? oci_identity_dynamic_group.nodes[0].name : null
    }
    access = {
      oci = {
        command = "oci ce cluster create-kubeconfig --cluster-id ${oci_containerengine_cluster.main.id} --file $HOME/.kube/config --region ${local.region} --token-version 2.0.0 --kube-endpoint PRIVATE_ENDPOINT"
      }
    }
  }
}

// Write status to JSON file
resource "local_file" "status" {
  filename = local.status_file_path
  content  = jsonencode(local.status_data)

  file_permission      = "0644"
  directory_permission = "0755"
}
