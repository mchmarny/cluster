terraform {
  backend "s3" {
    # Backend configuration provided via -backend-config during terraform init
    # This allows the same code to work with different buckets/accounts
  }
}
