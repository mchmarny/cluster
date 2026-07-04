// Package oci provides Oracle Cloud Infrastructure-specific config-derived
// naming helpers (BucketName, StateKey, OutputFileName). OKE uses the Terraform
// s3 backend against OCI Object Storage's S3-compatibility endpoint, so the
// state naming mirrors the aws helper package.
package oci
