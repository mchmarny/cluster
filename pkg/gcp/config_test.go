package gcp

import (
	"testing"

	"github.com/mchmarny/cluster/pkg/config"
)

func TestGCPConfigHelpers(t *testing.T) {
	cfg := &config.Config{
		Deployment: config.Deployment{
			ID:       "d1",
			Provider: config.ProviderGKE,
			Tenancy:  "my-project",
			Location: "us-west1",
		},
		Cluster: map[string]config.ProviderConfig{
			"gke": {Version: "1.33"},
		},
	}

	tests := []struct {
		name string
		fn   func(*config.Config) string
		want string
	}{
		{"BucketName", BucketName, "cluster-state-my-project"},
		{"StatePrefix", StatePrefix, "deployments/us-west1/d1"},
		{"OutputFileName", OutputFileName, "d1-my-project-output.json"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := tt.fn(cfg); got != tt.want {
				t.Errorf("%s() = %q, want %q", tt.name, got, tt.want)
			}
		})
	}
}
