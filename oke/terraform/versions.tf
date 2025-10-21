terraform {
  required_version = ">= 1.13.0"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 6.19.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13.1"
    }
    http = {
      source  = "hashicorp/http"
      version = "~> 3.5.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5.3"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1.0"
    }
  }
}
