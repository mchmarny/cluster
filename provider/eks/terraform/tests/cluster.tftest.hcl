# EKS access entries for adminRoles (cluster.tf)
# bootstrap_cluster_creator_admin_permissions=true auto-creates an access entry
# for the deploying principal — an explicit entry for the same role 409s.
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

run "creator_role_excluded_from_admin_access_entries" {
  command = plan

  assert {
    condition     = length(aws_eks_access_entry.admin_roles) == 1
    error_message = "adminRoles entry matching the cluster creator must be skipped (EKS bootstrap already created it)"
  }

  assert {
    condition = contains(
      keys(aws_eks_access_entry.admin_roles),
      "arn:aws:iam::123456789012:role/other-admin"
    )
    error_message = "non-creator adminRoles must still get an explicit access entry"
  }

  assert {
    condition     = length(aws_eks_access_policy_association.admin_cluster_admin) == 1
    error_message = "policy associations must match the filtered access entries"
  }
}
