package config

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
)

func TestResolveFromPath(t *testing.T) {
	yaml := `
deployment:
  id: test
  provider: eks
  tenancy: "123"
  location: us-west-2
cluster:
  name: test
  version: "1.33"
`
	path := filepath.Join(t.TempDir(), "config.yaml")
	if err := os.WriteFile(path, []byte(yaml), 0644); err != nil {
		t.Fatal(err)
	}

	got, cleanup, err := Resolve(path, "")
	defer cleanup()
	if err != nil {
		t.Fatalf("Resolve() error: %v", err)
	}
	if got != path {
		t.Errorf("Resolve() = %q, want %q", got, path)
	}
}

func TestResolveFromBase64(t *testing.T) {
	yaml := `
deployment:
  id: test
  provider: eks
  tenancy: "123"
  location: us-west-2
cluster:
  name: test
  version: "1.33"
`
	encoded := base64.StdEncoding.EncodeToString([]byte(yaml))

	got, cleanup, err := Resolve("", encoded)
	if err != nil {
		t.Fatalf("Resolve() error: %v", err)
	}
	defer cleanup()

	data, err := os.ReadFile(got)
	if err != nil {
		t.Fatalf("reading resolved file: %v", err)
	}

	if string(data) != yaml {
		t.Errorf("resolved content mismatch")
	}

	// Verify cleanup removes the file
	cleanup()
	if _, err := os.Stat(got); err == nil {
		t.Error("cleanup did not remove temp file")
	}
}

func TestResolveNoInput(t *testing.T) {
	_, _, err := Resolve("", "")
	if err == nil {
		t.Error("expected error, got nil")
	}
}

func TestResolveInvalidBase64(t *testing.T) {
	_, _, err := Resolve("", "not-valid-base64!!!")
	if err == nil {
		t.Error("expected error for invalid base64, got nil")
	}
}
