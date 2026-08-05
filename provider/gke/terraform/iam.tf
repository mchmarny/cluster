// =====================================================================================
// Service Account for System Node Pool
// =====================================================================================

resource "google_service_account" "system_nodes" {
  account_id   = "${local.name_prefix}-system-nodes"
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

resource "google_project_iam_member" "system_nodes_default_sa" {
  project = local.project
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.system_nodes.email}"
}

// =====================================================================================
// Service Account for Worker Node Pools
// =====================================================================================

resource "google_service_account" "worker_nodes" {
  account_id   = "${local.name_prefix}-worker-nodes"
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

resource "google_project_iam_member" "worker_nodes_default_sa" {
  project = local.project
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.worker_nodes.email}"
}

// compute.instanceAdmin.v1 grants instance-level operations needed for GPU/multi-NIC
// node pools without granting full Compute Engine control (firewall, network, etc.)
resource "google_project_iam_member" "worker_nodes_compute_instance_admin" {
  project = local.project
  role    = "roles/compute.instanceAdmin.v1"
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

