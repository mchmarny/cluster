terraform {
  required_version = ">= 1.13.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.21"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.21"
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
