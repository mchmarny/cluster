# Cluster, network, and identity wiring (cluster.tf / network.tf / iam.tf)
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
  target = data.oci_core_services.all
  values = {
    services = [{
      id         = "ocid1.service.oc1..all"
      name       = "All ORD Services In Oracle Services Network"
      cidr_block = "all-ord-services-in-oracle-services-network"
    }]
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
  target = oci_kms_key.etcd
  values = {
    id = "ocid1.key.oc1..etcd"
  }
}

variables {
  CONFIG_PATH = "tests/config.yaml"
}

run "subnets_derived_from_vcn_cidr" {
  command = plan

  assert {
    condition     = oci_core_subnet.control_plane.cidr_block == "10.0.4.0/28"
    error_message = "Control-plane subnet must be 10.0.4.0/28"
  }

  assert {
    condition     = oci_core_subnet.system.cidr_block == "10.0.0.0/22"
    error_message = "System subnet must be 10.0.0.0/22"
  }

  assert {
    condition     = oci_core_subnet.pod.cidr_block == "10.0.64.0/18"
    error_message = "Pod subnet must be 10.0.64.0/18"
  }

  assert {
    condition     = oci_core_subnet.worker.cidr_block == "10.0.128.0/17"
    error_message = "Worker subnet must be 10.0.128.0/17"
  }
}

run "control_plane_reachable_from_nodes_and_pods" {
  command = plan

  assert {
    condition = toset(keys(oci_core_network_security_group_security_rule.cp_ingress_clients)) == toset([
      "nodes-6443", "nodes-12250", "pods-6443", "pods-12250",
    ])
    error_message = "Nodes and pods must reach the control plane on 6443 and 12250"
  }

  assert {
    condition     = contains(keys(oci_core_network_security_group_security_rule.cp_ingress_api), "203.0.113.10/32")
    error_message = "Caller egress IP must be allowed to the API endpoint"
  }
}

run "lb_security_list_isolated_from_control_plane" {
  command = apply

  assert {
    condition     = length(setintersection(toset(oci_core_subnet.control_plane.security_list_ids), toset(oci_core_subnet.lb.security_list_ids))) == 0
    error_message = "Cloud-controller LB rules must not land on a security list attached to the API endpoint subnet"
  }
}

run "service_gateway_uses_all_services" {
  command = plan

  assert {
    condition     = one(oci_core_service_gateway.main.services).service_id == "ocid1.service.oc1..all"
    error_message = "Service gateway must target the 'All <region> Services' entry"
  }
}

run "etcd_key_policy_scoped_to_key" {
  command = apply

  assert {
    condition     = oci_identity_policy.oke_kms[0].compartment_id == "ocid1.compartment.oc1..tftest"
    error_message = "KMS policy must live in the deployment compartment"
  }

  assert {
    condition = tolist(oci_identity_policy.oke_kms[0].statements) == tolist([
      "Allow service oke to use keys in compartment id ocid1.compartment.oc1..tftest where target.key.id = 'ocid1.key.oc1..etcd'",
      "Allow any-user to use keys in compartment id ocid1.compartment.oc1..tftest where ALL {request.principal.type = 'cluster', target.key.id = 'ocid1.key.oc1..etcd'}",
    ])
    error_message = "KMS policy must grant OKE and the cluster principal use of exactly the etcd key"
  }
}

run "tenancy_identity_opt_in" {
  command = plan

  assert {
    condition     = length(oci_identity_dynamic_group.nodes) == 0 && length(oci_identity_policy.nodes) == 0
    error_message = "Tenancy-level dynamic group/policy must not be created unless identity.manage is true"
  }
}
