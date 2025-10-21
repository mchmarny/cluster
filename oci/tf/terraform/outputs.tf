output "cluster_id" {
  description = "OCID of the OKE cluster"
  value       = oci_containerengine_cluster.main.id
}

output "cluster_name" {
  description = "Name of the OKE cluster"
  value       = local.cluster_name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint"
  value       = oci_containerengine_cluster.main.endpoints[0].private_endpoint
}

output "cluster_version" {
  description = "Kubernetes version"
  value       = oci_containerengine_cluster.main.kubernetes_version
}

output "vcn_id" {
  description = "OCID of the VCN"
  value       = oci_core_vcn.main.id
}

output "vcn_cidr" {
  description = "CIDR block of the VCN"
  value       = local.vcn_cidr
}

output "pod_cidr" {
  description = "CIDR block for pods"
  value       = local.pod_cidr
}

output "service_cidr" {
  description = "CIDR block for services"
  value       = local.service_cidr
}

output "node_pools" {
  description = "Node pool details"
  value = {
    for k, v in oci_containerengine_node_pool.pools : k => {
      id                 = v.id
      name               = v.name
      kubernetes_version = v.kubernetes_version
      node_shape         = v.node_shape
      size               = v.node_config_details[0].size
    }
  }
}

output "kubeconfig_path" {
  description = "Path to the generated kubeconfig file"
  value       = local_sensitive_file.kubeconfig.filename
}

output "region" {
  description = "OCI region"
  value       = local.region
}

output "compartment_id" {
  description = "OCID of the compartment"
  value       = local.compartment_ocid
}

output "dynamic_group_id" {
  description = "OCID of the dynamic group for node pools"
  value       = oci_identity_dynamic_group.node_pools.id
}

output "status" {
  description = "Deployment status information"
  value = jsonencode({
    deploymentId  = local.prefix
    region        = local.region
    compartmentId = local.compartment_ocid
    tenancyId     = local.tenancy_ocid
    cluster = {
      id             = oci_containerengine_cluster.main.id
      name           = local.cluster_name
      version        = oci_containerengine_cluster.main.kubernetes_version
      endpoint       = oci_containerengine_cluster.main.endpoints[0].private_endpoint
      kubeconfigPath = local_sensitive_file.kubeconfig.filename
    }
    network = {
      vcnId       = oci_core_vcn.main.id
      vcnCidr     = local.vcn_cidr
      podCidr     = local.pod_cidr
      serviceCidr = local.service_cidr
      subnets = {
        public      = { for k, v in oci_core_subnet.public : k => { id = v.id, cidr = v.cidr_block } }
        apiEndpoint = { for k, v in oci_core_subnet.api_endpoint : k => { id = v.id, cidr = v.cidr_block } }
        nodePools   = { for k, v in oci_core_subnet.node_pools : k => { id = v.id, cidr = v.cidr_block } }
        pods        = { for k, v in oci_core_subnet.pods : k => { id = v.id, cidr = v.cidr_block } }
      }
    }
    nodePools = {
      for k, v in oci_containerengine_node_pool.pools : k => {
        id                = v.id
        name              = v.name
        kubernetesVersion = v.kubernetes_version
        nodeShape         = v.node_shape
        size              = v.node_config_details[0].size
      }
    }
    iam = {
      dynamicGroupId = oci_identity_dynamic_group.node_pools.id
    }
    lastUpdated = local.updateTime
  })
}

# Write status to file
resource "local_file" "status" {
  content         = jsonencode(local.status)
  filename        = local.statusFilePath
  file_permission = "0644"
}
