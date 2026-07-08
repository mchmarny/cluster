package azure

import (
	"testing"

	"github.com/mchmarny/cluster/pkg/config"
)

func TestAzureConfigHelpers(t *testing.T) {
	cfg := &config.Config{
		Deployment: config.Deployment{
			ID:       "demo",
			Provider: config.ProviderAKS,
			Tenancy:  "11112222-3333-4444-5555-666677778888",
			Location: "eastus",
			State:    "tenancy",
		},
		Cluster: map[string]config.ProviderConfig{
			"aks": {Name: "test", Version: "1.33"},
		},
	}

	tests := []struct {
		name string
		got  string
		want string
	}{
		{"ResourceGroupName", ResourceGroupName(cfg), "cluster-state-rg"},
		{"ContainerName", ContainerName(cfg), "tfstate"},
		{"StorageAccountName", StorageAccountName(cfg), "clst11112222333344445555"},
		{"BucketName", BucketName(cfg), "clst11112222333344445555"},
		{"StateKey", StateKey(cfg), "deployments/eastus/demo/terraform.tfstate"},
		{"OutputFileName", OutputFileName(cfg), "demo-11112222-3333-4444-5555-666677778888-output.json"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.got != tt.want {
				t.Errorf("%s = %q, want %q", tt.name, tt.got, tt.want)
			}
		})
	}
}

// TestStorageAccountNameConstraints verifies the derived name always satisfies
// Azure's Storage Account naming rules: 3-24 chars, lowercase alphanumeric.
func TestStorageAccountNameConstraints(t *testing.T) {
	cfg := &config.Config{
		Deployment: config.Deployment{
			Tenancy: "AABBCCDD-EEFF-0011-2233-445566778899",
		},
	}
	name := StorageAccountName(cfg)
	if len(name) < 3 || len(name) > 24 {
		t.Errorf("StorageAccountName length = %d, want 3..24 (%q)", len(name), name)
	}
	for _, r := range name {
		if (r < 'a' || r > 'z') && (r < '0' || r > '9') {
			t.Errorf("StorageAccountName contains invalid char %q in %q", r, name)
		}
	}
}
