// =====================================================================================
// KMS Vault + Key for Kubernetes secret (etcd) encryption
// =====================================================================================

locals {
  // etcd encryption toggle (default on). Creating a KMS vault requires KMS
  // manage permissions in the compartment; guard with try() in config.
  etcd_encryption_enabled = try(local.config.security.etcdEncryption.enabled, true)
}

resource "oci_kms_vault" "main" {
  count = local.etcd_encryption_enabled ? 1 : 0

  compartment_id = local.compartment
  display_name   = "${local.prefix}-oke-vault"
  vault_type     = "DEFAULT"
  freeform_tags  = local.tags
}

resource "oci_kms_key" "etcd" {
  count = local.etcd_encryption_enabled ? 1 : 0

  compartment_id      = local.compartment
  display_name        = "${local.prefix}-oke-etcd"
  management_endpoint = oci_kms_vault.main[0].management_endpoint
  protection_mode     = "SOFTWARE"
  freeform_tags       = local.tags

  key_shape {
    algorithm = "AES"
    length    = 32 // 256-bit
  }
}

// =====================================================================================
// OKE Cluster
// =====================================================================================

resource "oci_containerengine_cluster" "main" {
  compartment_id     = local.compartment
  name               = local.cluster_name
  kubernetes_version = local.oke_version
  vcn_id             = oci_core_vcn.main.id
  type               = "ENHANCED_CLUSTER"
  freeform_tags      = local.tags

  // etcd encryption via customer-managed KMS key (best-effort; toggle above).
  kms_key_id = local.etcd_encryption_enabled ? oci_kms_key.etcd[0].id : null

  // Native pod networking (required for the pod subnet / OCI_VCN_IP_NATIVE CNI).
  cluster_pod_network_options {
    cni_type = "OCI_VCN_IP_NATIVE"
  }

  // Control-plane endpoint. Private by default; allowed CIDRs are enforced via
  // the control-plane NSG (see network.tf).
  endpoint_config {
    is_public_ip_enabled = local.is_public_ip_enabled
    subnet_id            = oci_core_subnet.control_plane.id
    nsg_ids              = [oci_core_network_security_group.control_plane.id]
  }

  options {
    service_lb_subnet_ids = [oci_core_subnet.lb.id]

    // Legacy add-ons disabled (dashboard + Tiller are deprecated/insecure).
    add_ons {
      is_kubernetes_dashboard_enabled = false
      is_tiller_enabled               = false
    }

    kubernetes_network_config {
      pods_cidr     = local.pods_cidr
      services_cidr = local.services_cidr
    }
  }

  timeouts {
    create = "45m"
    update = "45m"
    delete = "45m"
  }
}
