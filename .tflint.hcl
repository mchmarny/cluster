# .tflint.hcl
config {
  format = "compact"
  call_module_type = "local"  # or "registry"
  force = false
  disabled_by_default = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.43.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

plugin "google" {
    enabled = true
    version = "0.36.0"
    source  = "github.com/terraform-linters/tflint-ruleset-google"
}

rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}