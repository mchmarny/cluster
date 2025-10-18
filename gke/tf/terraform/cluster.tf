// =====================================================================================
// KMS Key for GKE Secrets Encryption
// =====================================================================================

resource "google_kms_key_ring" "gke" {
  count = local.secrets_encryption_enabled ? 1 : 0

  name     = "${local.prefix}-gke-keyring"
  location = local.region
  project  = local.project
}

resource "google_kms_crypto_key" "gke_secrets" {
  count = local.secrets_encryption_enabled ? 1 : 0

  name     = "${local.prefix}-gke-secrets"
  key_ring = google_kms_key_ring.gke[0].id
  purpose  = "ENCRYPT_DECRYPT"

  rotation_period = "7776000s" # 90 days

  lifecycle {
    prevent_destroy = false # Set to true in production
  }
}

resource "google_kms_crypto_key_iam_member" "gke_secrets_encrypter" {
  count = local.secrets_encryption_enabled ? 1 : 0

  crypto_key_id = google_kms_crypto_key.gke_secrets[0].id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:service-${data.google_project.current.number}@container-engine-robot.iam.gserviceaccount.com"
}

// =====================================================================================
// GKE Cluster
// =====================================================================================

resource "google_container_cluster" "main" {
  provider = google-beta

  name     = local.config.cluster.name
  location = local.region
  project  = local.project

  # Specify version OR release channel, not both
  min_master_version = local.release_channel == null ? local.gke_version : null

  # We manage node pools separately
  remove_default_node_pool = true
  initial_node_count       = 1

  # Delete protection
  deletion_protection = local.deletion_protection

  network    = google_compute_network.main.id
  subnetwork = google_compute_subnetwork.main[keys(local.node_subnets)[0]].id

  # Release channel (RAPID, REGULAR, STABLE)
  dynamic "release_channel" {
    for_each = local.release_channel != null ? [1] : []
    content {
      channel = local.release_channel
    }
  }

  # Networking configuration
  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = try(local.secondary_ranges[keys(local.node_subnets)[0]].pods.rangeName, null)
    services_secondary_range_name = try(local.secondary_ranges[keys(local.node_subnets)[0]].services.rangeName, null)
  }

  # Private cluster configuration
  dynamic "private_cluster_config" {
    for_each = local.private_cluster_enabled ? [1] : []
    content {
      enable_private_nodes    = true
      enable_private_endpoint = false
      master_ipv4_cidr_block  = local.master_ipv4_cidr_block
    }
  }

  # Master authorized networks
  master_authorized_networks_config {
    dynamic "cidr_blocks" {
      for_each = local.authorized_networks
      content {
        cidr_block   = cidr_blocks.value.cidr_block
        display_name = cidr_blocks.value.display_name
      }
    }
  }

  # Workload Identity
  dynamic "workload_identity_config" {
    for_each = local.workload_identity_enabled ? [1] : []
    content {
      workload_pool = "${local.project}.svc.id.goog"
    }
  }

  # Database encryption (secrets encryption)
  dynamic "database_encryption" {
    for_each = local.secrets_encryption_enabled ? [1] : []
    content {
      state    = "ENCRYPTED"
      key_name = google_kms_crypto_key.gke_secrets[0].id
    }
  }

  # Addons
  addons_config {
    gce_persistent_disk_csi_driver_config {
      enabled = try(local.config.cluster.addons.gcePersistentDiskCsiDriver, true)
    }

    gcp_filestore_csi_driver_config {
      enabled = local.filestore_csi_enabled
    }

    gcs_fuse_csi_driver_config {
      enabled = local.gcs_fuse_csi_enabled
    }
  }

  # Binary Authorization
  dynamic "binary_authorization" {
    for_each = local.binary_authorization_enabled ? [1] : []
    content {
      evaluation_mode = "PROJECT_SINGLETON_POLICY_ENFORCE"
    }
  }

  # Maintenance policy
  maintenance_policy {
    daily_maintenance_window {
      start_time = local.maintenance_start_time
    }
  }

  # Enable Autopilot features
  cluster_autoscaling {
    enabled = false # We manage node pools manually
  }

  # Cluster tags
  resource_labels = merge(local.config.deployment.tags, {
    "last-sync" = local.updateTime
  })

  # Lifecycle
  lifecycle {
    ignore_changes = [
      # Ignore changes to initial_node_count as we manage node pools separately
      initial_node_count,
    ]
  }

  depends_on = [
    google_kms_crypto_key_iam_member.gke_secrets_encrypter,
    google_project_iam_member.system_nodes_log_writer,
    google_project_iam_member.system_nodes_metric_writer,
  ]

  timeouts {
    create = "45m"
    update = "45m"
    delete = "45m"
  }
}
