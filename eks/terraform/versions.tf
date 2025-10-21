terraform {
  required_version = ">= 1.13.0"

  required_providers {
    aws   = { source = "hashicorp/aws", version = "~> 6.14.1" }
    time  = { source = "hashicorp/time", version = "~> 0.13.1" }
    http  = { source = "hashicorp/http", version = "~> 3.5.0" }
    local = { source = "hashicorp/local", version = "~> 2.5.3" }
    tls   = { source = "hashicorp/tls", version = "~> 4.1.0" }
  }
}
