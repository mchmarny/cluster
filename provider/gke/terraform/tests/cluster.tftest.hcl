# Default node pool placement (cluster.tf node_locations, node_config).
# GKE creates the default pool in three zones it picks in the region before
# remove_default_node_pool deletes it, so a single-zone stockout fails cluster
# create unless the config can pin its zones and machine type.
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
  CONFIG_PATH = "tests/config-short.yaml"
}

run "unset_keeps_gke_default_placement" {
  command = plan

  # Unset must stay null so existing clusters plan no changes
  assert {
    condition     = local.cluster_zones == null
    error_message = "cluster.gke.zones unset must leave node_locations to GKE"
  }

  assert {
    condition     = local.default_pool_machine_type == null
    error_message = "cluster.gke.defaultPool.machineType unset must omit node_config"
  }
}

run "zones_and_default_pool_machine_type_applied" {
  command = plan

  variables {
    CONFIG_PATH = "tests/config-zones.yaml"
  }

  assert {
    condition     = google_container_cluster.main.node_locations == toset(["us-central1-c"])
    error_message = "cluster.gke.zones must set node_locations, got ${jsonencode(google_container_cluster.main.node_locations)}"
  }

  assert {
    condition     = google_container_cluster.main.node_config[0].machine_type == "e2-standard-4"
    error_message = "cluster.gke.defaultPool.machineType must set node_config.machine_type"
  }
}

run "zones_outside_region_rejected" {
  command = plan

  variables {
    CONFIG_PATH = "tests/config-zones-outside-region.yaml"
  }

  expect_failures = [
    google_container_cluster.main,
  ]
}

run "empty_zones_behaves_like_unset" {
  command = plan

  variables {
    CONFIG_PATH = "tests/config-zones-empty.yaml"
  }

  assert {
    condition     = length(local.cluster_zones) == 0
    error_message = "cluster.gke.zones: [] must pass the region precondition and leave the zones to GKE"
  }
}

run "create_with_zones" {
  command = apply

  variables {
    CONFIG_PATH = "tests/config-zones.yaml"
  }
}

run "zones_and_default_pool_changes_ignored_after_create" {
  command = plan

  variables {
    CONFIG_PATH = "tests/config-zones-changed.yaml"
  }

  # Ignored drift must still be surfaced at plan
  expect_failures = [
    check.cluster_zones,
  ]

  # GKE moves every node pool when cluster locations change, including pools
  # pinned to their own zones; zones must only shape the cluster at create
  assert {
    condition     = google_container_cluster.main.node_locations == toset(["us-central1-c"])
    error_message = "changing cluster.gke.zones on an existing cluster must plan no change, got ${jsonencode(google_container_cluster.main.node_locations)}"
  }

  # The default pool is gone after create; its machine type must not drive a diff
  assert {
    condition     = google_container_cluster.main.node_config[0].machine_type == "e2-standard-4"
    error_message = "changing cluster.gke.defaultPool.machineType on an existing cluster must plan no change"
  }
}
