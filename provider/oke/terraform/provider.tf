// OCI provider authenticates from ~/.oci/config: OCI_AUTH selects the method
// (ApiKey by default, SecurityToken for `oci session authenticate`) and
// OCI_CONFIG_FILE_PROFILE the profile. No keys are hardcoded here. region and
// tenancy are sourced from the config-driven locals.
provider "oci" {
  region       = local.region
  tenancy_ocid = local.tenancy
}

// IAM writes (policies, dynamic groups) are only accepted in the tenancy's home
// region, which is derived from the tenancy rather than configured.
provider "oci" {
  alias        = "home"
  region       = local.home_region
  tenancy_ocid = local.tenancy
}
