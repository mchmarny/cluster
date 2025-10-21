terraform {
  backend "s3" {
    # Backend configuration will be provided via backend-config flags
    # This allows the same code to work with different buckets/compartments
    skip_region_validation      = true
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    force_path_style            = true
  }
}
