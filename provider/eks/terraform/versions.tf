terraform {
  required_version = ">= 1.15.0"

  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 6.47" }
    time  = { source = "hashicorp/time", version = "~> 0.13" }
    http  = { source = "hashicorp/http", version = "~> 3.5" }
    local = { source = "hashicorp/local", version = "~> 2.5" }
    tls   = { source = "hashicorp/tls", version = "~> 4.1" }
  }
}
