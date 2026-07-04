package oci

import (
	"fmt"

	"github.com/mchmarny/cluster/pkg/config"
)

// stateBucket is the OCI Object Storage bucket that holds Terraform state.
// Bucket names are scoped to a tenancy's Object Storage namespace, so a fixed
// name is unique per tenancy without embedding the (long) tenancy OCID.
const stateBucket = "cluster-state"

// BucketName returns the OCI Object Storage bucket name for Terraform state.
func BucketName(_ *config.Config) string {
	return stateBucket
}

// StateKey returns the object key for the Terraform state file. OKE uses the
// Terraform s3 backend against OCI's S3-compatibility endpoint, so the key
// layout matches the aws helper package.
func StateKey(cfg *config.Config) string {
	return fmt.Sprintf("deployments/%s/%s/terraform.tfstate",
		cfg.Deployment.Location, cfg.Deployment.ID)
}

// OutputFileName returns the output file name for this deployment.
func OutputFileName(cfg *config.Config) string {
	return fmt.Sprintf("%s-%s-output.json", cfg.Deployment.ID, cfg.Deployment.Tenancy)
}
