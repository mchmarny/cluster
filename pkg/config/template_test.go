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

	// Verify EKS template nests correctly under cluster.eks / compute.eks
	if !strings.Contains(content, "  eks:") {
		t.Error("EKS template must nest config under 'cluster.eks:' and 'compute.eks:'")
	}

	// Verify the generated template produces a loadable config when required fields are filled
	patched := strings.Replace(content, "# tenancy: \"123456789012\"", "tenancy: \"123456789012\"", 1)
	patchedPath := filepath.Join(t.TempDir(), "eks-patched.yaml")
	if err := os.WriteFile(patchedPath, []byte(patched), 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(patchedPath); err != nil {
		t.Errorf("EKS template failed to load after filling required fields: %v", err)
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
