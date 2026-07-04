terraform {
  // OCI Object Storage via S3-compatibility endpoint; not AWS.
  // Partial config (bucket, key, region, endpoints, credentials) is supplied
  // via -backend-config at `terraform init`. OKE points the standard s3
  // backend at OCI Object Storage's S3-compatible API, so no AWS account is
  // involved. Requires skip_region_validation / skip_credentials_validation
  // / skip_metadata_api_check in the -backend-config for non-AWS endpoints.
  backend "s3" {}
}
