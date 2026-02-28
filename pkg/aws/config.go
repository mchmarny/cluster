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

// SAName returns the IAM service account name for this deployment.
func SAName(cfg *config.Config) string {
	return fmt.Sprintf("%s-builder-sa", cfg.Deployment.ID)
}

// PolicyName returns the IAM policy name for this deployment.
func PolicyName(cfg *config.Config) string {
	return fmt.Sprintf("%s-builder-policy", cfg.Deployment.ID)
}

// PolicyARN returns the IAM policy ARN for this deployment.
func PolicyARN(cfg *config.Config) string {
	return fmt.Sprintf("arn:aws:iam::%s:policy/%s", cfg.Deployment.Tenancy, PolicyName(cfg))
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
