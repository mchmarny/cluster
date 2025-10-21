# OKE Cluster
resource "oci_containerengine_cluster" "main" {
  compartment_id     = local.compartment_ocid
  name               = local.cluster_name
  vcn_id             = oci_core_vcn.main.id
  kubernetes_version = local.oke_version
  type               = "ENHANCED_CLUSTER"

  cluster_pod_network_options {
    cni_type = "OCI_VCN_IP_NATIVE"
  }

  endpoint_config {
    is_public_ip_enabled = false
    subnet_id            = values(oci_core_subnet.api_endpoint)[0].id
    nsg_ids              = [oci_core_network_security_group.control_plane.id]
  }

  options {
    service_lb_subnet_ids = [for s in oci_core_subnet.public : s.id]

    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }

    kubernetes_network_config {
      pods_cidr     = local.pod_cidr
      services_cidr = local.service_cidr
    }

    persistent_volume_config {
      freeform_tags = local.freeform_tags
    }

    service_lb_config {
      freeform_tags = local.freeform_tags
    }
  }

  freeform_tags = local.freeform_tags

  lifecycle {
    ignore_changes = [
      # Ignore changes to tags that OCI adds automatically
      defined_tags,
    ]
  }
}

# Cluster addons
resource "oci_containerengine_addon" "cluster_autoscaler" {
  count = try(local.config.cluster.addons.clusterAutoscaler, false) ? 1 : 0

  addon_name                       = "ClusterAutoscaler"
  cluster_id                       = oci_containerengine_cluster.main.id
  remove_addon_resources_on_delete = true
}

resource "oci_containerengine_addon" "kubernetes_dashboard" {
  count = try(local.config.cluster.addons.kubernetesDashboard, false) ? 1 : 0

  addon_name                       = "KubernetesDashboard"
  cluster_id                       = oci_containerengine_cluster.main.id
  remove_addon_resources_on_delete = true
}

resource "oci_containerengine_addon" "cert_manager" {
  count = try(local.config.cluster.addons.certManager, false) ? 1 : 0

  addon_name                       = "CertManager"
  cluster_id                       = oci_containerengine_cluster.main.id
  remove_addon_resources_on_delete = true
}

# Generate kubeconfig
resource "local_sensitive_file" "kubeconfig" {
  content = templatefile("${path.module}/templates/kubeconfig.tpl", {
    cluster_id       = oci_containerengine_cluster.main.id
    cluster_name     = local.cluster_name
    cluster_endpoint = oci_containerengine_cluster.main.endpoints[0].private_endpoint
    region           = local.region
  })
  filename        = "${local.configDir}/${local.cluster_name}-kubeconfig"
  file_permission = "0600"
}
