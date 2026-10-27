// =====================================================================================
// KMS Vault + Key for Kubernetes secret (etcd) encryption
// =====================================================================================

locals {
  // etcd encryption toggle (default on). Needs KMS and policy manage
  // permissions in the compartment. Destroying a vault or key only schedules
  // deletion (7-30 days), so repeated create/destroy cycles accumulate them.
  etcd_encryption_enabled = try(local.config.security.secretsEncryption.enabled, true)
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

// OKE encrypts etcd with the key only if both the OKE service and the cluster's
// own resource principal may use it. The policy is compartment-scoped (no
// tenancy admin needed) and pinned to the key.
resource "oci_identity_policy" "oke_kms" {
  count    = local.etcd_encryption_enabled ? 1 : 0
  provider = oci.home

  compartment_id = local.compartment
  name           = "${local.iam_prefix}-oke-kms"
  description    = "Allow OKE to use the etcd encryption key for ${local.cluster_name}"
  freeform_tags  = local.tags

  statements = [
    "Allow service oke to use keys in ${local.policy_scope} where target.key.id = '${oci_kms_key.etcd[0].id}'",
    "Allow any-user to use keys in ${local.policy_scope} where ALL {request.principal.type = 'cluster', target.key.id = '${oci_kms_key.etcd[0].id}'}",
  ]

  lifecycle {
    create_before_destroy = true
  }
}

// IAM is eventually consistent; cluster create fails if the policy has not
// propagated yet.
resource "time_sleep" "oke_kms_policy" {
  count = local.etcd_encryption_enabled ? 1 : 0

  create_duration = "60s"
  triggers = {
    statements = join("\n", oci_identity_policy.oke_kms[0].statements)
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

  // etcd encryption via customer-managed KMS key. Create-time only: toggling
  // security.secretsEncryption.enabled replaces the cluster.
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

  lifecycle {
    precondition {
      condition     = contains(["image", "operator"], local.gpu_driver)
      error_message = "cluster.oke.gpuDriver must be 'image' or 'operator', got '${local.gpu_driver}'."
    }
  }

  depends_on = [time_sleep.oke_kms_policy]

  timeouts {
    create = "45m"
    update = "45m"
    delete = "45m"
  }
}
