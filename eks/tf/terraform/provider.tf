provider "aws" {
  region = local.region
  default_tags {
    tags = local.config.deployment.tags
  }
}
