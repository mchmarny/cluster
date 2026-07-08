package cluster

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/mchmarny/cluster/pkg/config"
	"github.com/mchmarny/cluster/pkg/state"
)

func TestResolveGCPCredentialsEmpty(t *testing.T) {
	// Unset GOOGLE_APPLICATION_CREDENTIALS for this test
	orig := os.Getenv("GOOGLE_APPLICATION_CREDENTIALS")
	os.Unsetenv("GOOGLE_APPLICATION_CREDENTIALS")
	defer func() {
		if orig != "" {
			os.Setenv("GOOGLE_APPLICATION_CREDENTIALS", orig)
		}
	}()

	path, cleanup, err := resolveGCPCredentials("")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer cleanup()

	if path != "" {
		t.Errorf("path = %q, want empty", path)
	}
}

func TestResolveGCPCredentialsFromEnv(t *testing.T) {
	orig := os.Getenv("GOOGLE_APPLICATION_CREDENTIALS")
	os.Setenv("GOOGLE_APPLICATION_CREDENTIALS", "/tmp/test-creds.json")
	defer func() {
		if orig != "" {
			os.Setenv("GOOGLE_APPLICATION_CREDENTIALS", orig)
		} else {
			os.Unsetenv("GOOGLE_APPLICATION_CREDENTIALS")
		}
	}()

	path, cleanup, err := resolveGCPCredentials("")
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer cleanup()

	if path != "/tmp/test-creds.json" {
		t.Errorf("path = %q, want /tmp/test-creds.json", path)
	}
}

func TestResolveGCPCredentialsFromBase64(t *testing.T) {
	creds := `{"type":"service_account","project_id":"test"}`
	encoded := base64.StdEncoding.EncodeToString([]byte(creds))

	path, cleanup, err := resolveGCPCredentials(encoded)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	defer cleanup()

	if path == "" {
		t.Fatal("expected non-empty path")
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading temp file: %v", err)
	}
	if string(data) != creds {
		t.Errorf("content = %q, want %q", data, creds)
	}

	// Verify cleanup removes the file
	cleanup()
	if _, err := os.Stat(path); !os.IsNotExist(err) {
		t.Errorf("cleanup did not remove temp file: %s", path)
	}
}

func TestResolveGCPCredentialsInvalidBase64(t *testing.T) {
	_, _, err := resolveGCPCredentials("not-valid!!!")
	if err == nil {
		t.Error("expected error for invalid base64")
	}
}

func TestResolveCredentialsFromKeyContent(t *testing.T) {
	keyJSON := `{"AccessKey":{"AccessKeyId":"AKIATEST","SecretAccessKey":"secret123","UserName":"test"}}`
	encoded := base64.StdEncoding.EncodeToString([]byte(keyJSON))

	cfg := &config.Config{
		Deployment: config.Deployment{
			ID:       "test",
			Provider: "eks",
			Tenancy:  "123",
			Location: "us-west-2",
			State:    "tenancy",
		},
		Cluster: map[string]config.ProviderConfig{
			"eks": {Version: "1.33"},
		},
	}

	keyID, secret := resolveCredentials(encoded, t.TempDir(), cfg)
	if keyID != "AKIATEST" {
		t.Errorf("keyID = %q, want AKIATEST", keyID)
	}
	if secret != "secret123" {
		t.Errorf("secret = %q, want secret123", secret)
	}
}

func TestResolveCredentialsFromEnv(t *testing.T) {
	origID := os.Getenv("AWS_ACCESS_KEY_ID")
	origSecret := os.Getenv("AWS_SECRET_ACCESS_KEY")
	os.Setenv("AWS_ACCESS_KEY_ID", "ENVID")
	os.Setenv("AWS_SECRET_ACCESS_KEY", "ENVSECRET")
	defer func() {
		if origID != "" {
			os.Setenv("AWS_ACCESS_KEY_ID", origID)
		} else {
			os.Unsetenv("AWS_ACCESS_KEY_ID")
		}
		if origSecret != "" {
			os.Setenv("AWS_SECRET_ACCESS_KEY", origSecret)
		} else {
			os.Unsetenv("AWS_SECRET_ACCESS_KEY")
		}
	}()

	cfg := &config.Config{
		Deployment: config.Deployment{
			ID:       "test",
			Provider: "eks",
			Tenancy:  "123",
			Location: "us-west-2",
			State:    "tenancy",
		},
		Cluster: map[string]config.ProviderConfig{
			"eks": {Version: "1.33"},
		},
	}

	keyID, secret := resolveCredentials("", t.TempDir(), cfg)
	if keyID != "ENVID" {
		t.Errorf("keyID = %q, want ENVID", keyID)
	}
	if secret != "ENVSECRET" {
		t.Errorf("secret = %q, want ENVSECRET", secret)
	}
}

func TestResolveCredentialsFromStateFile(t *testing.T) {
	// Clear env vars
	origID := os.Getenv("AWS_ACCESS_KEY_ID")
	origSecret := os.Getenv("AWS_SECRET_ACCESS_KEY")
	os.Unsetenv("AWS_ACCESS_KEY_ID")
	os.Unsetenv("AWS_SECRET_ACCESS_KEY")
	defer func() {
		if origID != "" {
			os.Setenv("AWS_ACCESS_KEY_ID", origID)
		}
		if origSecret != "" {
			os.Setenv("AWS_SECRET_ACCESS_KEY", origSecret)
		}
	}()

	cfg := &config.Config{
		Deployment: config.Deployment{
			ID:       "test",
			Provider: "eks",
			Tenancy:  "123",
			Location: "us-west-2",
			State:    "tenancy",
		},
		Cluster: map[string]config.ProviderConfig{
			"eks": {Version: "1.33"},
		},
	}

	dir := t.TempDir()
	keyJSON := []byte(`{"AccessKey":{"AccessKeyId":"AKIAFILE","SecretAccessKey":"filesecret","UserName":"test"}}`)
	if err := state.WriteKey(dir, "test-123-key.json", keyJSON); err != nil {
		t.Fatal(err)
	}

	keyID, secret := resolveCredentials("", dir, cfg)
	if keyID != "AKIAFILE" {
		t.Errorf("keyID = %q, want AKIAFILE", keyID)
	}
	if secret != "filesecret" {
		t.Errorf("secret = %q, want filesecret", secret)
	}
}

func TestResolveCredentialsFallsThrough(t *testing.T) {
	origID := os.Getenv("AWS_ACCESS_KEY_ID")
	origSecret := os.Getenv("AWS_SECRET_ACCESS_KEY")
	os.Unsetenv("AWS_ACCESS_KEY_ID")
	os.Unsetenv("AWS_SECRET_ACCESS_KEY")
	defer func() {
		if origID != "" {
			os.Setenv("AWS_ACCESS_KEY_ID", origID)
		}
		if origSecret != "" {
			os.Setenv("AWS_SECRET_ACCESS_KEY", origSecret)
		}
	}()

	cfg := &config.Config{
		Deployment: config.Deployment{
			ID:       "test",
			Provider: "eks",
			Tenancy:  "123",
			Location: "us-west-2",
			State:    "tenancy",
		},
		Cluster: map[string]config.ProviderConfig{
			"eks": {Version: "1.33"},
		},
	}

	keyID, secret := resolveCredentials("", t.TempDir(), cfg)
	if keyID != "" || secret != "" {
		t.Errorf("expected empty fallthrough, got %q / %q", keyID, secret)
	}
}

func TestGkeImportTargets(t *testing.T) {
	cfg := &config.Config{
		Deployment: config.Deployment{
			ID:       "demo",
			Tenancy:  "my-project",
			Location: "us-central1",
		},
	}

	targets := gkeImportTargets(cfg)
	if len(targets) != 1 {
		t.Fatalf("got %d targets, want 1", len(targets))
	}
	if targets[0].Address != "google_kms_key_ring.gke[0]" {
		t.Errorf("address = %q", targets[0].Address)
	}
	want := "projects/my-project/locations/us-central1/keyRings/demo-gke-keyring"
	if targets[0].ID != want {
		t.Errorf("id = %q, want %q", targets[0].ID, want)
	}
}

func TestGenerateTemplateEKSLoads(t *testing.T) {
	path := filepath.Join(t.TempDir(), "eks-test.yaml")
	if err := config.GenerateTemplate(path); err != nil {
		t.Fatal(err)
	}

	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}

	// Fill required fields: uncomment tenancy line
	content := strings.Replace(string(data),
		`# tenancy: "123456789012"  # REQUIRED: Your AWS account ID`,
		`tenancy: "123456789012"`,
		1)

	patchedPath := filepath.Join(t.TempDir(), "eks-patched.yaml")
	writeErr := os.WriteFile(patchedPath, []byte(content), 0644)
	if writeErr != nil {
		t.Fatal(writeErr)
	}

	cfg, loadErr := config.Load(patchedPath)
	if loadErr != nil {
		t.Fatalf("Load failed: %v", loadErr)
	}
	if cfg.Deployment.Provider != "eks" {
		t.Errorf("provider = %q, want eks", cfg.Deployment.Provider)
	}
}

func TestExtractStatus(t *testing.T) {
	tests := []struct {
		name string
		data string
		want string
	}{
		{
			name: "status output present",
			data: `{"status":{"sensitive":true,"value":{"deployment":{"prefix":"aks-test"}}}}`,
			want: `"prefix": "aks-test"`,
		},
		{
			name: "no status output",
			data: `{"other":{"value":"x"}}`,
			want: `{"other":{"value":"x"}}`,
		},
		{
			name: "invalid json returned as-is",
			data: `not-json`,
			want: `not-json`,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := string(extractStatus([]byte(tt.data)))
			if !strings.Contains(got, tt.want) {
				t.Errorf("extractStatus() = %q, want it to contain %q", got, tt.want)
			}
		})
	}
}
