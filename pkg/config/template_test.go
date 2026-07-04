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

func TestGenerateTemplateAKS(t *testing.T) {
	path := filepath.Join(t.TempDir(), "aks-test.yaml")

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
		"provider: aks",
		"cluster:",
		"compute:",
		"tenancy:",
		"location:",
		"state: tenancy",
		"vmSize",
		"nodePools",
	} {
		if !strings.Contains(content, want) {
			t.Errorf("missing %q in AKS template", want)
		}
	}

	// Verify AKS template nests correctly under cluster.aks / compute.aks
	if !strings.Contains(content, "  aks:") {
		t.Error("AKS template must nest config under 'cluster.aks:' and 'compute.aks:'")
	}

	// Verify the generated template produces a loadable config when required fields are filled
	patched := strings.Replace(content,
		"# tenancy: \"00000000-0000-0000-0000-000000000000\"",
		"tenancy: \"00000000-0000-0000-0000-000000000000\"", 1)
	patchedPath := filepath.Join(t.TempDir(), "aks-patched.yaml")
	if err := os.WriteFile(patchedPath, []byte(patched), 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(patchedPath); err != nil {
		t.Errorf("AKS template failed to load after filling required fields: %v", err)
	}
}

func TestGenerateTemplateOKE(t *testing.T) {
	path := filepath.Join(t.TempDir(), "oke-test.yaml")

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
		"provider: oke",
		"cluster:",
		"compute:",
		"tenancy:",
		"location:",
		"state: tenancy",
		"shape",
		"nodePools",
	} {
		if !strings.Contains(content, want) {
			t.Errorf("missing %q in OKE template", want)
		}
	}

	// Verify OKE template nests correctly under cluster.oke / compute.oke
	if !strings.Contains(content, "  oke:") {
		t.Error("OKE template must nest config under 'cluster.oke:' and 'compute.oke:'")
	}

	// Verify the generated template produces a loadable config when required fields are filled
	patched := strings.Replace(content,
		"# tenancy: \"ocid1.tenancy.oc1..aaaa\"",
		"tenancy: \"ocid1.tenancy.oc1..aaaa\"", 1)
	patchedPath := filepath.Join(t.TempDir(), "oke-patched.yaml")
	if err := os.WriteFile(patchedPath, []byte(patched), 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := Load(patchedPath); err != nil {
		t.Errorf("OKE template failed to load after filling required fields: %v", err)
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
