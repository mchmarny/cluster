# Self-managed fabric pools (GPU memory clusters) in compute.tf
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
    regions = [{ key = "SJC", name = "us-sanjose-1" }]
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
    availability_domains = [{ name = "VSwX:AP-KULAI-2-AD-1" }]
  }
}

override_data {
  target = data.oci_core_services.all
  values = {
    services = [{
      id         = "ocid1.service.oc1..all"
      name       = "All KUL Services In Oracle Services Network"
      cidr_block = "all-kul-services-in-oracle-services-network"
    }]
  }
}

override_data {
  target = data.oci_containerengine_node_pool_option.images["X86_64"]
  values = {
    shapes = ["VM.Standard.E5.Flex", "VM.Standard.A1.Flex", "BM.GPU.L40S.4", "BM.GPU.GB300.4"]
    sources = [
      { image_id = "x86-cpu", source_type = "IMAGE", source_name = "Oracle-Linux-8.10-2026.09.18-0-OKE-1.36.4-1923" },
    ]
  }
}

override_data {
  target = data.oci_containerengine_node_pool_option.images["AARCH64"]
  values = {
    shapes  = ["VM.Standard.E5.Flex", "BM.GPU.GB300.4"]
    sources = []
  }
}

override_data {
  target = data.oci_containerengine_cluster_kube_config.main
  values = {
    content = "clusters:\n- cluster:\n    certificate-authority-data: Q0EtREFUQQ==\n    server: https://10.0.4.2:6443\n  name: tftest\n"
  }
}

override_resource {
  target = oci_containerengine_cluster.main
  values = {
    id        = "ocid1.cluster.oc1..tftest"
    endpoints = [{ private_endpoint = "10.0.4.2:6443", public_endpoint = "", kubernetes = "", vcn_hostname_endpoint = "", ipv6endpoint = "" }]
  }
}

variables {
  CONFIG_PATH = "tests/config-fabric.yaml"
}

run "fabric_pool_is_self_managed" {
  command = apply

  assert {
    condition     = !contains(keys(oci_containerengine_node_pool.pools), "gb300") && contains(keys(oci_containerengine_node_pool.pools), "system")
    error_message = "Pools with gpuMemoryFabricId must not become OKE managed node pools"
  }

  assert {
    condition     = oci_core_compute_gpu_memory_cluster.fabric["gb300"].gpu_memory_fabric_id == "ocid1.computegpumemoryfabric.oc1..tftest" && oci_core_compute_gpu_memory_cluster.fabric["gb300"].size == "2"
    error_message = "GPU memory cluster must target the configured fabric and size"
  }
}

run "fabric_nodes_carry_join_metadata" {
  command = apply

  assert {
    condition = (
      oci_core_instance_configuration.fabric["gb300"].instance_details[0].launch_details[0].extended_metadata["apiserver_host"] == "10.0.4.2" &&
      oci_core_instance_configuration.fabric["gb300"].instance_details[0].launch_details[0].extended_metadata["cluster_ca_cert"] == "Q0EtREFUQQ==" &&
      oci_core_instance_configuration.fabric["gb300"].instance_details[0].launch_details[0].extended_metadata["oke-k8version"] == "v1.36.4"
    )
    error_message = "Instance configuration must carry the private API host, cluster CA, and version"
  }

  assert {
    condition     = oci_core_instance_configuration.fabric["gb300"].instance_details[0].launch_details[0].shape == "BM.GPU.GB300.4"
    error_message = "gpuType gb300 must resolve to BM.GPU.GB300.4 for fabric pools"
  }

  assert {
    condition     = oci_core_instance_configuration.fabric["gb300"].instance_details[0].launch_details[0].metadata["pod-subnets"] == oci_core_subnet.pod.id
    error_message = "Self-managed nodes must use the VCN-native pod subnet"
  }
}

run "cluster_join_scoped_to_cluster" {
  command = apply

  assert {
    condition     = strcontains(one(oci_identity_policy.cluster_join[0].statements), "target.cluster.id = 'ocid1.cluster.oc1..tftest'")
    error_message = "CLUSTER_JOIN must be scoped to this cluster"
  }
}
