package config

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGenerateTemplateEKS(t *testing.T) {
	path := filepath.Join(t.TempDir(), "eks-test.yaml")

	if err := GenerateTemplate(path); err != nil {
		t.Fatalf("GenerateTemplate() error: %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading generated file: %v", err)
	}

	content := string(data)

	for _, want := range []string{
		"apiVersion:",
		"deployment:",
		"provider: eks",
		"cluster:",
		"compute:",
		"tenancy:",
		"location:",
		"state: tenancy",
		"instanceType",
		"nodeGroups",
	} {
		if !strings.Contains(content, want) {
			t.Errorf("missing %q in EKS template", want)
		}
	}
}

func TestGenerateTemplateGKE(t *testing.T) {
	path := filepath.Join(t.TempDir(), "gke-test.yaml")

	if err := GenerateTemplate(path); err != nil {
		t.Fatalf("GenerateTemplate() error: %v", err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading generated file: %v", err)
	}

	content := string(data)

	for _, want := range []string{
		"apiVersion:",
		"deployment:",
		"provider: gke",
		"cluster:",
		"compute:",
		"tenancy:",
		"location:",
		"state: tenancy",
		"machineType",
		"nodePools",
		"guestAccelerator",
		"gpuDriverInstallation",
		"hostMaintenancePolicy",
		"maintenanceInterval: PERIODIC",
		"capacityReservations",
		"taints",
	} {
		if !strings.Contains(content, want) {
			t.Errorf("missing %q in GKE template", want)
		}
	}
}

func TestGenerateTemplateNoOverwrite(t *testing.T) {
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte("existing"), 0644); err != nil {
		t.Fatal(err)
	}

	if err := GenerateTemplate(path); err == nil {
		t.Error("expected error for existing file, got nil")
	}
}
