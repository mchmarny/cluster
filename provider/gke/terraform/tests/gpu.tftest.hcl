# GPU node pool guards (compute.tf).
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
  CONFIG_PATH = "tests/config-gpu.yaml"
}

run "a3_mega_without_gvnic_net_plans" {
  command = plan

  assert {
    condition     = length(google_compute_network.gvnic) == 0
    error_message = "gVNIC network must not be created when gpuNets.gvnicCidr is unset"
  }

  assert {
    condition     = length(google_container_node_pool.pools["gpu-worker"].network_config[0].additional_node_network_configs) == 8
    error_message = "a3-megagpu-8g pool must attach exactly its 8 GPU NIC networks"
  }
}

run "host_maintenance_interval_applied_when_set" {
  command = plan

  # PERIODIC reservations reject nodes created with an unspecified interval
  assert {
    condition     = google_container_node_pool.pools["gpu-worker"].node_config[0].host_maintenance_policy[0].maintenance_interval == "PERIODIC"
    error_message = "nodeConfig.hostMaintenanceInterval must set node_config.host_maintenance_policy.maintenance_interval"
  }

  assert {
    condition     = length(google_container_node_pool.pools["cpu-worker"].node_config[0].host_maintenance_policy) == 0
    error_message = "host_maintenance_policy must be omitted when nodeConfig.hostMaintenanceInterval is unset"
  }
}

run "a3_mega_with_gvnic_net_rejected" {
  command = plan

  variables {
    CONFIG_PATH = "tests/config-gpu-gvnic.yaml"
  }

  expect_failures = [
    google_container_node_pool.pools,
  ]
}
