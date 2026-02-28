package terraform

import (
	"testing"

	"github.com/mchmarny/cluster/pkg/config"
)

func TestBuildInitArgsS3(t *testing.T) {
	args := buildInitArgs(config.StateTenancy, "my-bucket", "us-west-2", "deployments/us-west-2/demo/terraform.tfstate")
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
	args := buildInitArgs(config.StateLocal, "", "", "")
	if len(args) != 1 || args[0] != "init" {
		t.Errorf("args = %v, want [init]", args)
	}
}

func TestBuildEnv(t *testing.T) {
	cfg := RunConfig{
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
		ConfigPath: "/tmp/config.yaml",
	}

	env := buildEnv(cfg)

	for _, e := range env {
		if e == "AWS_ACCESS_KEY_ID=" || e == "AWS_SECRET_ACCESS_KEY=" {
			t.Errorf("should not include empty cred: %q", e)
		}
	}
}
