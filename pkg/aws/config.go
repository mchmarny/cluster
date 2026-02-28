package aws

import (
	"fmt"

	"github.com/mchmarny/cluster/pkg/config"
)

// KeyFileName returns the state key file name for this deployment.
func KeyFileName(cfg *config.Config) string {
	return fmt.Sprintf("%s-%s-key.json", cfg.Deployment.ID, cfg.Deployment.Tenancy)
}

// OutputFileName returns the output file name for this deployment.
func OutputFileName(cfg *config.Config) string {
	return fmt.Sprintf("%s-%s-output.json", cfg.Deployment.ID, cfg.Deployment.Tenancy)
}

// BucketName returns the S3 state bucket name for this deployment.
func BucketName(cfg *config.Config) string {
	return fmt.Sprintf("cluster-state-%s", cfg.Deployment.Tenancy)
}

// StateKey returns the S3 object key for the Terraform state file.
func StateKey(cfg *config.Config) string {
	return fmt.Sprintf("deployments/%s/%s/terraform.tfstate",
		cfg.Deployment.Location, cfg.Deployment.ID)
}
