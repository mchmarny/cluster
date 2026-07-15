# EFA network interface layout per GPU family (compute.tf locals)
# Run with: terraform test (providers are mocked — no AWS credentials needed)

mock_provider "aws" {
  # Generated mock values are random strings; policy fields must be valid JSON
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }
}
mock_provider "http" {}
mock_provider "local" {}
mock_provider "tls" {}
mock_provider "time" {}

override_data {
  target = data.aws_caller_identity.current
  values = {
    account_id = "123456789012"
    arn        = "arn:aws:sts::123456789012:assumed-role/AWSReservedSSO_CS-Admin_abc123/tester"
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

run "gb200_family_derived_from_instance_type" {
  command = plan

  # GB200 (p6e-gb200.*) uses the AWS-recommended network card indices,
  # each card holding a single interface at device_index 0
  assert {
    condition = [
      for ni in aws_launch_template.node_groups["tftest-gb200"].network_interfaces :
      tonumber(ni.network_card_index)
    ] == [0, 1, 5, 9, 13]
    error_message = "p6e-gb200.36xlarge must derive gpu_family=gb200 and use network cards 0,1,5,9,13"
  }

  assert {
    condition = alltrue([
      for ni in aws_launch_template.node_groups["tftest-gb200"].network_interfaces :
      tonumber(ni.device_index) == 0
    ])
    error_message = "GB200 interfaces must all use device_index=0 (one interface per network card)"
  }

  assert {
    condition = [
      for ni in aws_launch_template.node_groups["tftest-gb200"].network_interfaces :
      ni.interface_type
    ] == ["interface", "efa-only", "efa-only", "efa-only", "efa-only"]
    error_message = "GB200 card 0 must be 'interface', remaining cards 'efa-only'"
  }
}

run "explicit_accelerator_overrides_derivation" {
  command = plan

  assert {
    condition = [
      for ni in aws_launch_template.node_groups["tftest-accel"].network_interfaces :
      tonumber(ni.network_card_index)
    ] == [0, 1, 5, 9, 13]
    error_message = "accelerator: gb200 must force the GB200 EFA layout regardless of instance type"
  }
}

run "non_gpu_worker_gets_no_efa_interfaces" {
  command = plan

  assert {
    condition     = length(aws_launch_template.node_groups["tftest-cpu"].network_interfaces) == 0
    error_message = "non-GPU workers must not declare EFA network interfaces"
  }
}
