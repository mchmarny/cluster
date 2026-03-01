package gcp

import (
	"fmt"

	"github.com/mchmarny/cluster/pkg/config"
)

// BucketName returns the GCS state bucket name for this deployment.
func BucketName(cfg *config.Config) string {
	return fmt.Sprintf("cluster-state-%s", cfg.Deployment.Tenancy)
}

// StatePrefix returns the GCS object prefix for the Terraform state file.
func StatePrefix(cfg *config.Config) string {
	return fmt.Sprintf("deployments/%s/%s", cfg.Deployment.Location, cfg.Deployment.ID)
}

// OutputFileName returns the output file name for this deployment.
func OutputFileName(cfg *config.Config) string {
	return fmt.Sprintf("%s-%s-output.json", cfg.Deployment.ID, cfg.Deployment.Tenancy)
}
