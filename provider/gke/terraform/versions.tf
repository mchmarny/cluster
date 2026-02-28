terraform {
  required_version = ">= 1.13.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.21.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.21.0"
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
      version = "~> 2.7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.8.1"
    }
  }
}
