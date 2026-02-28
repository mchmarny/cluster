package aws

import (
	"testing"

	"github.com/mchmarny/cluster/pkg/config"
)

func TestAWSConfigHelpers(t *testing.T) {
	cfg := &config.Config{
		Deployment: config.Deployment{
			ID:       "demo",
			Provider: "eks",
			Tenancy:  "123456789012",
			Location: "us-west-2",
			State:    "tenancy",
		},
		Cluster: config.Cluster{Name: "test", Version: "1.33"},
	}

	tests := []struct {
		name string
		got  string
		want string
	}{
		{"KeyFileName", KeyFileName(cfg), "demo-123456789012-key.json"},
		{"SAName", SAName(cfg), "demo-builder-sa"},
		{"PolicyName", PolicyName(cfg), "demo-builder-policy"},
		{"PolicyARN", PolicyARN(cfg), "arn:aws:iam::123456789012:policy/demo-builder-policy"},
		{"BucketName", BucketName(cfg), "cluster-state-123456789012"},
		{"StateKey", StateKey(cfg), "deployments/us-west-2/demo/terraform.tfstate"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if tt.got != tt.want {
				t.Errorf("%s = %q, want %q", tt.name, tt.got, tt.want)
			}
		})
	}
}
