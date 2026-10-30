terraform {
  // Terraform's native OCI Object Storage backend. Partial config (bucket,
  // namespace, region, key) is supplied via -backend-config at init. The
  // backend does not read OCI_AUTH / OCI_CONFIG_FILE_PROFILE itself, so actuate
  // and the cluster CLI pass them as -backend-config auth / config_file_profile;
  // credentials come from ~/.oci/config.
  backend "oci" {}
}
