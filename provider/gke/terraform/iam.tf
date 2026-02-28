// =====================================================================================
// Service Account for GKE Cluster
// =====================================================================================

resource "google_service_account" "gke_cluster" {
  account_id   = "${local.prefix}-gke-cluster"
  display_name = "GKE Cluster Service Account for ${local.config.cluster.name}"
  description  = "Service account used by GKE cluster control plane"
  project      = local.project
}

// =====================================================================================
// Service Account for System Node Pool
// =====================================================================================

resource "google_service_account" "system_nodes" {
  account_id   = "${local.prefix}-system-nodes"
  display_name = "GKE System Nodes Service Account"
  description  = "Service account used by GKE system node pools"
  project      = local.project
}

resource "google_project_iam_member" "system_nodes_log_writer" {
  project = local.project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.system_nodes.email}"
}

resource "google_project_iam_member" "system_nodes_metric_writer" {
  project = local.project
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.system_nodes.email}"
}

resource "google_project_iam_member" "system_nodes_monitoring_viewer" {
  project = local.project
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.system_nodes.email}"
}

resource "google_project_iam_member" "system_nodes_resource_metadata_writer" {
  project = local.project
  role    = "roles/stackdriver.resourceMetadata.writer"
  member  = "serviceAccount:${google_service_account.system_nodes.email}"
}

// =====================================================================================
// Service Account for Worker Node Pools
// =====================================================================================

resource "google_service_account" "worker_nodes" {
  account_id   = "${local.prefix}-worker-nodes"
  display_name = "GKE Worker Nodes Service Account"
  description  = "Service account used by GKE worker node pools"
  project      = local.project
}

resource "google_project_iam_member" "worker_nodes_log_writer" {
  project = local.project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.worker_nodes.email}"
}

resource "google_project_iam_member" "worker_nodes_metric_writer" {
  project = local.project
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.worker_nodes.email}"
}

resource "google_project_iam_member" "worker_nodes_monitoring_viewer" {
  project = local.project
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.worker_nodes.email}"
}

resource "google_project_iam_member" "worker_nodes_resource_metadata_writer" {
  project = local.project
  role    = "roles/stackdriver.resourceMetadata.writer"
  member  = "serviceAccount:${google_service_account.worker_nodes.email}"
}

resource "google_project_iam_member" "worker_nodes_artifact_registry" {
  project = local.project
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.worker_nodes.email}"
}

// =====================================================================================
// Workload Identity Pool (if enabled)
// =====================================================================================

# Grant Kubernetes service accounts the ability to impersonate GCP service accounts
# Note: Workload Identity bindings are typically done per K8s service account
# For a general binding, we allow all K8s service accounts from specific namespaces
# Format: serviceAccount:PROJECT_ID.svc.id.goog[K8S_NAMESPACE/K8S_SA_NAME]

resource "google_service_account_iam_member" "workload_identity_user_system" {
  count = local.workload_identity_enabled ? 1 : 0

  service_account_id = google_service_account.system_nodes.name
  role               = "roles/iam.workloadIdentityUser"
  # Allow all K8s SAs in kube-system namespace
  member = "serviceAccount:${local.project}.svc.id.goog[kube-system/default]"
}

resource "google_service_account_iam_member" "workload_identity_user_worker" {
  count = local.workload_identity_enabled ? 1 : 0

  service_account_id = google_service_account.worker_nodes.name
  role               = "roles/iam.workloadIdentityUser"
  # Allow all K8s SAs in default namespace
  member = "serviceAccount:${local.project}.svc.id.goog[default/default]"
}

// =====================================================================================
// KMS Service Account (for secrets encryption)
// =====================================================================================

resource "google_service_account" "kms" {
  count = local.secrets_encryption_enabled ? 1 : 0

  account_id   = "${local.prefix}-gke-kms"
  display_name = "GKE KMS Service Account"
  description  = "Service account for GKE secrets encryption"
  project      = local.project
}
