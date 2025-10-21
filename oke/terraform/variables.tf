variable "CONFIG_PATH" {
  description = "Path to the YAML configuration file"
  type        = string
  default     = "../configs/demo.yaml"
}

variable "OCI_USER_OCID" {
  description = "OCI User OCID for authentication"
  type        = string
  sensitive   = true
}

variable "OCI_FINGERPRINT" {
  description = "Fingerprint for the OCI API key"
  type        = string
  sensitive   = true
}

variable "OCI_PRIVATE_KEY_PATH" {
  description = "Path to the OCI API private key file"
  type        = string
  sensitive   = true
}
