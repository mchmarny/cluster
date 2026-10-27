package oci

import (
	"fmt"

	"github.com/mchmarny/cluster/pkg/config"
)

// stateBucket is the OCI Object Storage bucket that holds Terraform state.
// Bucket names are scoped to a tenancy's Object Storage namespace, so a fixed
// name is unique per tenancy without embedding the (long) tenancy OCID.
const stateBucket = "cluster-state"

// NamespaceEnv names the env var carrying the tenancy's Object Storage
// namespace. The oci backend requires it and it cannot be derived from
// config; provider/oke/tools/setup resolves and prints it.
const NamespaceEnv = "OCI_NAMESPACE"

// BucketName returns the OCI Object Storage bucket name for Terraform state.
func BucketName(_ *config.Config) string {
	return stateBucket
}

// StateKey returns the object key for the Terraform state file, matching the
// key layout of the other providers.
func StateKey(cfg *config.Config) string {
	return fmt.Sprintf("deployments/%s/%s/terraform.tfstate",
		cfg.Deployment.Location, cfg.Deployment.ID)
}

// OutputFileName returns the output file name for this deployment.
func OutputFileName(cfg *config.Config) string {
	return fmt.Sprintf("%s-%s-output.json", cfg.Deployment.ID, cfg.Deployment.Tenancy)
}
