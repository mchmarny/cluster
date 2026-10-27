# Node pool shape, image, and placement resolution (main.tf / compute.tf locals)
# Run with: terraform test (providers are mocked — no OCI credentials needed)

mock_provider "oci" {}
mock_provider "oci" {
  alias = "home"
}
mock_provider "http" {}
mock_provider "local" {}
mock_provider "time" {}

override_data {
  target = data.oci_identity_tenancy.this
  values = {
    id              = "ocid1.tenancy.oc1..tftest"
    home_region_key = "SJC"
  }
}

override_data {
  target = data.oci_identity_regions.all
  values = {
    regions = [
      { key = "ORD", name = "us-chicago-1" },
      { key = "SJC", name = "us-sanjose-1" },
    ]
  }
}

override_data {
  target = data.http.egress_ip
  values = {
    response_body = "203.0.113.10"
  }
}

override_data {
  target = data.oci_identity_availability_domains.this
  values = {
    availability_domains = [
      { name = "Uocm:US-CHICAGO-1-AD-1" },
      { name = "Uocm:US-CHICAGO-1-AD-2" },
      { name = "Uocm:US-CHICAGO-1-AD-3" },
    ]
  }
}

override_data {
  target = data.oci_core_services.all
  values = {
    services = [{
      id         = "ocid1.service.oc1..all"
      name       = "All ORD Services In Oracle Services Network"
      cidr_block = "all-ord-services-in-oracle-services-network"
    }]
  }
}

# Catalog is deliberately unsorted: selection must come from the embedded build
# date, not the API order.
override_data {
  target = data.oci_containerengine_node_pool_option.images["X86_64"]
  values = {
    shapes = ["VM.Standard.E5.Flex", "VM.Standard.A1.Flex", "BM.GPU.L40S.4", "BM.GPU.GB300.4"]
    sources = [
      { image_id = "x86-cpu-old", source_type = "IMAGE", source_name = "Oracle-Linux-8.10-2026.08.14-0-OKE-1.36.4-1820" },
      { image_id = "x86-gpu-new", source_type = "IMAGE", source_name = "Oracle-Linux-8.10-Gen2-GPU-2026.09.18-0-OKE-1.36.4-1923" },
      { image_id = "x86-cpu-new", source_type = "IMAGE", source_name = "Oracle-Linux-8.10-2026.09.18-0-OKE-1.36.4-1923" },
      { image_id = "x86-gpu-old", source_type = "IMAGE", source_name = "Oracle-Linux-8.10-Gen2-GPU-2026.08.14-0-OKE-1.36.4-1820" },
    ]
  }
}

override_data {
  target = data.oci_containerengine_node_pool_option.images["AARCH64"]
  values = {
    shapes = ["VM.Standard.E5.Flex", "VM.Standard.A1.Flex", "BM.GPU.L40S.4", "BM.GPU.GB300.4"]
    sources = [
      { image_id = "arm-cpu-new", source_type = "IMAGE", source_name = "Oracle-Linux-8.10-aarch64-2026.09.18-0-OKE-1.36.4-1923" },
      { image_id = "arm-cpu-old", source_type = "IMAGE", source_name = "Oracle-Linux-8.10-aarch64-2026.08.14-0-OKE-1.36.4-1820" },
    ]
  }
}

variables {
  CONFIG_PATH = "tests/config.yaml"
}

run "gpu_type_maps_to_shape" {
  command = plan

  assert {
    condition     = oci_containerengine_node_pool.pools["l40s"].node_shape == "BM.GPU.L40S.4"
    error_message = "gpuType l40s must resolve to BM.GPU.L40S.4"
  }

  assert {
    condition     = oci_containerengine_node_pool.pools["gb300"].node_shape == "BM.GPU.GB300.4"
    error_message = "gpuType GB300 (any case) must resolve to BM.GPU.GB300.4"
  }
}

run "flex_shapes_get_shape_config" {
  command = plan

  assert {
    condition     = length(oci_containerengine_node_pool.pools["system"].node_shape_config) == 1
    error_message = "Flex shapes must emit node_shape_config"
  }

  assert {
    condition     = length(oci_containerengine_node_pool.pools["l40s"].node_shape_config) == 0
    error_message = "Fixed bare-metal shapes must not emit node_shape_config"
  }
}

run "image_selected_by_arch_gpu_and_build_date" {
  command = plan

  assert {
    condition     = oci_containerengine_node_pool.pools["system"].node_source_details[0].image_id == "x86-cpu-new"
    error_message = "x86 CPU pool must get the newest non-GPU x86 image"
  }

  assert {
    condition     = oci_containerengine_node_pool.pools["l40s"].node_source_details[0].image_id == "x86-gpu-new"
    error_message = "x86 GPU pool must get the newest GPU image"
  }

  assert {
    condition     = oci_containerengine_node_pool.pools["arm"].node_source_details[0].image_id == "arm-cpu-new"
    error_message = "Ampere (A1) pool must get the newest aarch64 image"
  }

  assert {
    condition     = oci_containerengine_node_pool.pools["gb300"].node_source_details[0].image_id == "ocid1.image.oc1..custom-gb300"
    error_message = "imageId must override platform image selection"
  }
}

run "custom_images_get_bootstrap" {
  command = plan

  assert {
    condition     = can(oci_containerengine_node_pool.pools["gb300"].node_metadata["user_data"])
    error_message = "Pools with imageId must carry the OKE bootstrap user_data"
  }
}

run "availability_domains_pin_placement" {
  command = apply

  assert {
    condition = [
      for p in oci_containerengine_node_pool.pools["l40s"].node_config_details[0].placement_configs : p.availability_domain
    ] == ["Uocm:US-CHICAGO-1-AD-3"]
    error_message = "availabilityDomains [3] must place only in AD-3"
  }

  assert {
    condition     = length(oci_containerengine_node_pool.pools["system"].node_config_details[0].placement_configs) == 3
    error_message = "Pools without availabilityDomains must spread across every AD"
  }
}

run "unknown_gpu_type_fails" {
  command = plan

  variables {
    CONFIG_PATH = "tests/config-unknown-gpu.yaml"
  }

  expect_failures = [oci_containerengine_node_pool.pools]
}

run "aarch64_gpu_without_image_fails" {
  command = plan

  variables {
    CONFIG_PATH = "tests/config-no-image.yaml"
  }

  expect_failures = [oci_containerengine_node_pool.pools]
}

run "shape_not_offered_fails" {
  command = plan

  variables {
    CONFIG_PATH = "tests/config-bad-shape.yaml"
  }

  expect_failures = [oci_containerengine_node_pool.pools]
}
