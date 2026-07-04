terraform {
  required_version = ">= 1.15.0"

  required_providers {
    // oracle/oci: current latest stable major is 8.x (registry-published).
    oci = {
      source  = "oracle/oci"
      version = "~> 8.21"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.5"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.7"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8"
    }
  }
}
