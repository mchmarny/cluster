# Node service-account naming (main.tf sa_prefix, iam.tf account_id).
# GCP caps a service-account account_id at 6-30 characters, so the derived
# "<prefix>-system-nodes" / "<prefix>-worker-nodes" names overflow once
# deployment.id exceeds 17 characters.
# Run with: terraform test (providers are mocked — no GCP credentials needed)

mock_provider "google" {}
mock_provider "google-beta" {}
mock_provider "http" {}
mock_provider "local" {}
mock_provider "time" {}
mock_provider "random" {}

override_data {
  target = data.google_project.current
  values = {
    project_id = "tftest-project"
  }
}

override_data {
  target = data.http.egress_ip
  values = {
    response_body = "203.0.113.10"
  }
}

variables {
  CONFIG_PATH = "tests/config.yaml"
}

run "long_deployment_id_fits_service_account_cap" {
  command = plan

  assert {
    condition     = length(google_service_account.system_nodes.account_id) <= 30
    error_message = "system node service account exceeds the GCP 30-char account_id cap: ${google_service_account.system_nodes.account_id}"
  }

  assert {
    condition     = length(google_service_account.worker_nodes.account_id) <= 30
    error_message = "worker node service account exceeds the GCP 30-char account_id cap: ${google_service_account.worker_nodes.account_id}"
  }

  # System and worker accounts must stay distinct after any shortening
  assert {
    condition     = google_service_account.system_nodes.account_id != google_service_account.worker_nodes.account_id
    error_message = "system and worker node service accounts collided"
  }
}

run "long_deployment_id_fits_node_pool_name_cap" {
  command = plan

  # GKE caps node pool names at 40 characters
  assert {
    condition = alltrue([
      for pool in google_container_node_pool.pools : length(pool.name) <= 40
    ])
    error_message = "node pool name exceeds the GKE 40-char cap: ${join(", ", [for pool in google_container_node_pool.pools : pool.name])}"
  }
}

run "short_deployment_id_keeps_raw_names" {
  command = plan

  variables {
    CONFIG_PATH = "tests/config-short.yaml"
  }

  # Ids that already fit must not be rewritten — renaming would replace the
  # service accounts (and the node pools bound to them) on deployed clusters
  assert {
    condition     = google_service_account.system_nodes.account_id == "tftest-system-nodes"
    error_message = "short deployment.id must keep the raw name, got ${google_service_account.system_nodes.account_id}"
  }

  assert {
    condition     = google_service_account.worker_nodes.account_id == "tftest-worker-nodes"
    error_message = "short deployment.id must keep the raw name, got ${google_service_account.worker_nodes.account_id}"
  }

  assert {
    condition     = google_container_node_pool.pools["system"].name == "tftest-system"
    error_message = "short deployment.id must keep the raw node pool name, got ${google_container_node_pool.pools["system"].name}"
  }
}
