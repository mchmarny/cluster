provider "aws" {
  region = local.region
  default_tags {
    tags = local.effective_tags
  }
}
