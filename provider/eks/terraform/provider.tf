provider "aws" {
  region = local.region
  default_tags {
    tags = merge(local.effective_tags, local.common_tags)
  }
}
