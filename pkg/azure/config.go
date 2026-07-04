package azure

import (
	"fmt"
	"strings"

	"github.com/mchmarny/cluster/pkg/config"
)

// stateResourceGroup is the resource group that holds the Terraform state
// Storage Account. It is bootstrapped by provider/aks/tools/setup.
const stateResourceGroup = "cluster-state-rg"

// stateContainer is the Blob container that holds Terraform state objects.
const stateContainer = "tfstate"

// ResourceGroupName returns the resource group name that backs the Terraform
// state Storage Account.
func ResourceGroupName(_ *config.Config) string {
	return stateResourceGroup
}

// ContainerName returns the Blob container name for Terraform state.
func ContainerName(_ *config.Config) string {
	return stateContainer
}

// StorageAccountName returns the Azure Storage Account name used for remote
// state. Storage account names are globally unique and constrained to 3-24
// lowercase alphanumeric characters, so it is derived deterministically from
// the subscription ID (dashes stripped) with a "clst" prefix.
func StorageAccountName(cfg *config.Config) string {
	hex := strings.ToLower(strings.ReplaceAll(cfg.Deployment.Tenancy, "-", ""))
	hex = strings.Map(func(r rune) rune {
		if (r >= 'a' && r <= 'z') || (r >= '0' && r <= '9') {
			return r
		}
		return -1
	}, hex)

	const prefix = "clst"
	const maxLen = 24
	name := prefix + hex
	if len(name) > maxLen {
		name = name[:maxLen]
	}
	return name
}

// BucketName is an alias for StorageAccountName, provided for symmetry with the
// aws and gcp helper packages (which name their state container "Bucket").
func BucketName(cfg *config.Config) string {
	return StorageAccountName(cfg)
}

// StateKey returns the Blob object key for the Terraform state file.
func StateKey(cfg *config.Config) string {
	return fmt.Sprintf("deployments/%s/%s/terraform.tfstate",
		cfg.Deployment.Location, cfg.Deployment.ID)
}

// OutputFileName returns the output file name for this deployment.
func OutputFileName(cfg *config.Config) string {
	return fmt.Sprintf("%s-%s-output.json", cfg.Deployment.ID, cfg.Deployment.Tenancy)
}
