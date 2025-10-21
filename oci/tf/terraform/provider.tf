provider "oci" {
  tenancy_ocid     = local.tenancy_ocid
  user_ocid        = var.OCI_USER_OCID
  fingerprint      = var.OCI_FINGERPRINT
  private_key_path = var.OCI_PRIVATE_KEY_PATH
  region           = local.region

  ignore_defined_tags = ["Oracle-Tags.CreatedBy", "Oracle-Tags.CreatedOn"]
}
