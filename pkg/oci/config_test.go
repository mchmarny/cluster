package oci

import (
	"testing"

	"github.com/mchmarny/cluster/pkg/config"
)

func TestOCIConfigHelpers(t *testing.T) {
	cfg := &config.Config{
		Deployment: config.Deployment{
			ID:       "demo",
			Provider: config.ProviderOKE,
			Tenancy:  "ocid1.tenancy.oc1..aaaaexample",
			Location: "us-ashburn-1",
			State:    "tenancy",
		},
		Cluster: map[string]config.ProviderConfig{
			"oke": {Name: "test", Version: "v1.33.1"},
		},
	}

	tests := []struct {
		name string
		got  string
		want string
	}{
		{"BucketName", BucketName(cfg), "cluster-state"},
		{"StateKey", StateKey(cfg), "deployments/us-ashburn-1/demo/terraform.tfstate"},
		{"OutputFileName", OutputFileName(cfg), "demo-ocid1.tenancy.oc1..aaaaexample-output.json"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.got != tt.want {
				t.Errorf("%s = %q, want %q", tt.name, tt.got, tt.want)
			}
		})
	}
}
