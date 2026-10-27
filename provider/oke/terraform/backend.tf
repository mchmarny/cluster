terraform {
  // Terraform's native OCI Object Storage backend. Partial config (bucket,
  // namespace, region, key) is supplied via -backend-config at init; auth is
  // read from OCI_AUTH / OCI_CONFIG_FILE_PROFILE and ~/.oci/config.
  backend "oci" {}
}
