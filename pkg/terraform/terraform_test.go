package terraform

import (
	"testing"

	"github.com/mchmarny/cluster/pkg/config"
)

func TestBuildInitArgsS3(t *testing.T) {
	args := buildInitArgs(RunConfig{
		Provider: config.ProviderEKS,
		State:    config.StateTenancy,
		Bucket:   "my-bucket",
		Region:   "us-west-2",
		StateKey: "deployments/us-west-2/demo/terraform.tfstate",
	})
	expected := []string{
		"init",
		"-backend-config=bucket=my-bucket",
		"-backend-config=region=us-west-2",
		"-backend-config=encrypt=true",
		"-backend-config=key=deployments/us-west-2/demo/terraform.tfstate",
	}

	if len(args) != len(expected) {
		t.Fatalf("len = %d, want %d\nargs: %v", len(args), len(expected), args)
	}
	for i, arg := range args {
		if arg != expected[i] {
			t.Errorf("args[%d] = %q, want %q", i, arg, expected[i])
		}
	}
}

func TestBuildInitArgsLocal(t *testing.T) {
	args := buildInitArgs(RunConfig{
		Provider: config.ProviderEKS,
		State:    config.StateLocal,
	})
	if len(args) != 1 || args[0] != "init" {
		t.Errorf("args = %v, want [init]", args)
	}
}

func TestBuildInitArgsGCS(t *testing.T) {
	args := buildInitArgs(RunConfig{
		Provider: config.ProviderGKE,
		State:    config.StateTenancy,
		Bucket:   "cluster-state-my-project",
		StateKey: "deployments/us-west1/d1",
	})
	expected := []string{
		"init",
		"-backend-config=bucket=cluster-state-my-project",
		"-backend-config=prefix=deployments/us-west1/d1",
	}

	if len(args) != len(expected) {
		t.Fatalf("len = %d, want %d\nargs: %v", len(args), len(expected), args)
	}
	for i, arg := range args {
		if arg != expected[i] {
			t.Errorf("args[%d] = %q, want %q", i, arg, expected[i])
		}
	}
}

func TestBuildEnv(t *testing.T) {
	cfg := RunConfig{
		Provider:        config.ProviderEKS,
		ConfigPath:      "/tmp/config.yaml",
		AccessKeyID:     "AKIA123",
		SecretAccessKey: "secret",
		Region:          "us-west-2",
	}

	env := buildEnv(cfg)

	want := map[string]bool{
		"TF_VAR_CONFIG_PATH=/tmp/config.yaml": true,
		"TF_IN_AUTOMATION=1":                  true,
		"AWS_ACCESS_KEY_ID=AKIA123":           true,
		"AWS_SECRET_ACCESS_KEY=secret":        true,
		"AWS_DEFAULT_REGION=us-west-2":        true,
	}

	for _, e := range env {
		if !want[e] {
			t.Errorf("unexpected env: %q", e)
		}
		delete(want, e)
	}

	for missing := range want {
		t.Errorf("missing env: %q", missing)
	}
}

func TestBuildEnvNoCreds(t *testing.T) {
	cfg := RunConfig{
		Provider:   config.ProviderEKS,
		ConfigPath: "/tmp/config.yaml",
	}

	env := buildEnv(cfg)

	for _, e := range env {
		if e == "AWS_ACCESS_KEY_ID=" || e == "AWS_SECRET_ACCESS_KEY=" {
			t.Errorf("should not include empty cred: %q", e)
		}
	}
}

func TestBuildEnvGKE(t *testing.T) {
	env := buildEnv(RunConfig{
		Provider:   config.ProviderGKE,
		ConfigPath: "/tmp/config.yaml",
	})

	if len(env) != 2 {
		t.Fatalf("got %d env vars, want 2: %v", len(env), env)
	}

	want := map[string]bool{
		"TF_VAR_CONFIG_PATH=/tmp/config.yaml": true,
		"TF_IN_AUTOMATION=1":                  true,
	}
	for _, e := range env {
		if !want[e] {
			t.Errorf("unexpected env var: %q", e)
		}
	}
}
