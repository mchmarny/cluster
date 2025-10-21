provider "google" {
  project = local.project
  region  = local.region

  default_labels = local.config.deployment.tags
}

provider "google-beta" {
  project = local.project
  region  = local.region

  default_labels = local.config.deployment.tags
}
