package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoad(t *testing.T) {
	yaml := `
apiVersion: github.com/mchmarny/cluster/v1alpha1
kind: Cluster
deployment:
  id: test-dep
  provider: eks
  tenancy: "123456789012"
  location: us-west-2
  state: tenancy
  destroy: false
  tags:
    owner: tester
    env: dev
cluster:
  eks:
    name: test-cluster
    version: "1.33"
`
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load() error: %v", err)
	}

	if cfg.Deployment.ID != "test-dep" {
		t.Errorf("Deployment.ID = %q, want %q", cfg.Deployment.ID, "test-dep")
	}
	if cfg.Deployment.Tenancy != "123456789012" {
		t.Errorf("Deployment.Tenancy = %q, want %q", cfg.Deployment.Tenancy, "123456789012")
	}
	if cfg.Deployment.Location != "us-west-2" {
		t.Errorf("Deployment.Location = %q, want %q", cfg.Deployment.Location, "us-west-2")
	}
	if cfg.Deployment.State != "tenancy" {
		t.Errorf("Deployment.State = %q, want %q", cfg.Deployment.State, "tenancy")
	}
	if cfg.Deployment.Destroy {
		t.Error("Deployment.Destroy = true, want false")
	}
	if cfg.Cluster["eks"].Name != "test-cluster" {
		t.Errorf("Cluster[eks].Name = %q, want %q", cfg.Cluster["eks"].Name, "test-cluster")
	}
}

func TestLoadDefaults(t *testing.T) {
	yaml := `
deployment:
  id: test-dep
  provider: eks
  tenancy: "123456789012"
  location: us-west-2
cluster:
  eks:
    version: "1.33"
`
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}

	cfg, err := Load(path)
	if err != nil {
		t.Fatalf("Load() error: %v", err)
	}

	if cfg.Deployment.State != "tenancy" {
		t.Errorf("default State = %q, want %q", cfg.Deployment.State, "tenancy")
	}
	if cfg.Deployment.Destroy {
		t.Error("default Destroy = true, want false")
	}
	if cfg.ClusterName() != "test-dep" {
		t.Errorf("default ClusterName() = %q, want %q (deployment.id)", cfg.ClusterName(), "test-dep")
	}
}

func TestLoadValidation(t *testing.T) {
	tests := []struct {
		name string
		yaml string
	}{
		{"missing id", `
deployment:
  provider: eks
  tenancy: "123"
  location: us-west-2
cluster:
  eks:
    name: test
    version: "1.33"
`},
		{"missing provider", `
deployment:
  id: test
  tenancy: "123"
  location: us-west-2
cluster:
  eks:
    name: test
    version: "1.33"
`},
		{"invalid provider", `
deployment:
  id: test
  provider: bad
  tenancy: "123"
  location: us-west-2
cluster:
  eks:
    name: test
    version: "1.33"
`},
		{"missing tenancy", `
deployment:
  id: test
  provider: eks
  location: us-west-2
cluster:
  eks:
    name: test
    version: "1.33"
`},
		{"missing location", `
deployment:
  id: test
  provider: eks
  tenancy: "123"
cluster:
  eks:
    name: test
    version: "1.33"
`},
		{"invalid state", `
deployment:
  id: test
  provider: eks
  tenancy: "123"
  location: us-west-2
  state: invalid
cluster:
  eks:
    name: test
    version: "1.33"
`},
		{"missing cluster version", `
deployment:
  id: test
  provider: eks
  tenancy: "123"
  location: us-west-2
cluster:
  eks:
    name: test
`},
		{"missing cluster section", `
deployment:
  id: test
  provider: eks
  tenancy: "123"
  location: us-west-2
cluster:
  gke:
    version: "1.33"
`},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := filepath.Join(t.TempDir(), "config.yaml")
			if err := os.WriteFile(path, []byte(tt.yaml), 0644); err != nil {
				t.Fatal(err)
			}
			_, err := Load(path)
			if err == nil {
				t.Error("expected error, got nil")
			}
		})
	}
}
