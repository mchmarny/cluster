// OCI provider authenticates via API key / config file (DEFAULT profile) or
// instance/workload principals from the environment. No keys are hardcoded
// here. region and tenancy are sourced from the config-driven locals.
provider "oci" {
  region       = local.region
  tenancy_ocid = local.tenancy
}
