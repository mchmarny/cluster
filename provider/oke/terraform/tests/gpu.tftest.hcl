# GPU driver modes (main.tf / compute.tf)
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

override_resource {
  target          = oci_kms_key.etcd
  override_during = plan
  values = {
    id = "ocid1.key.oc1..etcd"
  }
}

run "default_image_driver_keeps_oke_plugin" {
  command = plan

  variables {
    CONFIG_PATH = "tests/config.yaml"
  }

  assert {
    condition     = length([for l in oci_containerengine_node_pool.pools["l40s"].initial_node_labels : l if l.key == "oci.oraclecloud.com/disable-gpu-device-plugin"]) == 0
    error_message = "gpuDriver: image without the add-on must leave OKE's NvidiaGpuPlugin enabled"
  }

  assert {
    condition     = strcontains(oci_identity_policy.oke_kms[0].statements[0], " in compartment id ocid1.compartment.oc1..tftest ")
    error_message = "Non-root compartments must be addressed by id in policies"
  }
}

run "operator_driver_disables_plugin" {
  command = plan

  variables {
    CONFIG_PATH = "tests/config-gpu-operator.yaml"
  }

  assert {
    condition = anytrue([
      for l in oci_containerengine_node_pool.pools["l40s"].initial_node_labels : l.key == "oci.oraclecloud.com/disable-gpu-device-plugin"
    ])
    error_message = "gpuDriver: operator must disable OKE's NvidiaGpuPlugin on GPU pools"
  }

  assert {
    condition     = oci_containerengine_node_pool.pools["l40s"].node_source_details[0].image_id == "ocid1.image.oc1..ubuntu-driverless"
    error_message = "gpuDriver: operator must use the driverless imageId"
  }

  assert {
    condition     = strcontains(oci_identity_policy.oke_kms[0].statements[0], " in tenancy ")
    error_message = "Root compartment (compartmentId unset) must be addressed as 'tenancy' in policies"
  }
}

run "operator_driver_requires_image" {
  command = plan

  variables {
    CONFIG_PATH = "tests/config-gpu-operator-noimage.yaml"
  }

  expect_failures = [oci_containerengine_node_pool.pools]
}
