package terraform

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/mchmarny/cluster/pkg/config"
)

const tfInit = "terraform init"

// mockRunner records commands for verification.
type mockRunner struct {
	calls     []mockCall
	cmdOutput string
	cmdErr    error
	streamErr error
}

type mockCall struct {
	dir  string
	name string
	args []string
}

func (m *mockRunner) Cmd(_ context.Context, dir string, _ []string, name string, args ...string) (string, error) {
	m.calls = append(m.calls, mockCall{dir: dir, name: name, args: args})
	return m.cmdOutput, m.cmdErr
}

func (m *mockRunner) CmdStream(_ context.Context, dir string, _ []string, name string, args ...string) error {
	m.calls = append(m.calls, mockCall{dir: dir, name: name, args: args})
	return m.streamErr
}

func (m *mockRunner) cmdString(i int) string {
	if i >= len(m.calls) {
		return "<no call>"
	}
	c := m.calls[i]
	return fmt.Sprintf("%s %s", c.name, strings.Join(c.args, " "))
}

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

func TestPlanRunsInitThenPlan(t *testing.T) {
	m := &mockRunner{}
	err := Plan(context.Background(), RunConfig{
		TerraformDir: "/tf",
		ConfigPath:   "/tmp/c.yaml",
		Provider:     config.ProviderEKS,
		State:        config.StateLocal,
		Runner:       m,
	})
	if err != nil {
		t.Fatalf("Plan() error: %v", err)
	}
	if len(m.calls) != 2 {
		t.Fatalf("got %d calls, want 2", len(m.calls))
	}
	if m.cmdString(0) != tfInit {
		t.Errorf("call[0] = %q, want %q", m.cmdString(0), tfInit)
	}
	if m.cmdString(1) != "terraform plan" {
		t.Errorf("call[1] = %q, want 'terraform plan'", m.cmdString(1))
	}
}

func TestPlanInitError(t *testing.T) {
	m := &mockRunner{streamErr: fmt.Errorf("init failed")}
	err := Plan(context.Background(), RunConfig{
		TerraformDir: "/tf",
		Provider:     config.ProviderEKS,
		State:        config.StateLocal,
		Runner:       m,
	})
	if err == nil {
		t.Fatal("expected error, got nil")
	}
	if !strings.Contains(err.Error(), tfInit) {
		t.Errorf("error = %q, want to contain %q", err.Error(), tfInit)
	}
}

func TestPlanEmptyDir(t *testing.T) {
	err := Plan(context.Background(), RunConfig{})
	if err == nil || !strings.Contains(err.Error(), "terraform dir is required") {
		t.Errorf("Plan() error = %v, want 'terraform dir is required'", err)
	}
}

func TestRunApplySequence(t *testing.T) {
	m := &mockRunner{}
	err := Run(context.Background(), RunConfig{
		TerraformDir: "/tf",
		ConfigPath:   "/tmp/c.yaml",
		Provider:     config.ProviderEKS,
		State:        config.StateLocal,
		Runner:       m,
	})
	if err != nil {
		t.Fatalf("Run() error: %v", err)
	}
	if len(m.calls) != 3 {
		t.Fatalf("got %d calls, want 3", len(m.calls))
	}
	if m.cmdString(0) != tfInit {
		t.Errorf("call[0] = %q, want %q", m.cmdString(0), tfInit)
	}
	if m.cmdString(1) != "terraform plan -out=plan.cache" {
		t.Errorf("call[1] = %q, want 'terraform plan -out=plan.cache'", m.cmdString(1))
	}
	if m.cmdString(2) != "terraform apply plan.cache" {
		t.Errorf("call[2] = %q, want 'terraform apply plan.cache'", m.cmdString(2))
	}
}

func TestRunDestroySequence(t *testing.T) {
	m := &mockRunner{}
	err := Run(context.Background(), RunConfig{
		TerraformDir: "/tf",
		ConfigPath:   "/tmp/c.yaml",
		Provider:     config.ProviderGKE,
		State:        config.StateLocal,
		Destroy:      true,
		Runner:       m,
	})
	if err != nil {
		t.Fatalf("Run() error: %v", err)
	}
	if len(m.calls) != 3 {
		t.Fatalf("got %d calls, want 3", len(m.calls))
	}
	if m.cmdString(0) != tfInit {
		t.Errorf("call[0] = %q, want %q", m.cmdString(0), tfInit)
	}
	if m.cmdString(1) != "terraform refresh" {
		t.Errorf("call[1] = %q, want 'terraform refresh'", m.cmdString(1))
	}
	if m.cmdString(2) != "terraform destroy -auto-approve" {
		t.Errorf("call[2] = %q, want 'terraform destroy -auto-approve'", m.cmdString(2))
	}
}

func TestOutputSequence(t *testing.T) {
	m := &mockRunner{cmdOutput: `{"key":"val"}`}
	data, err := Output(context.Background(), RunConfig{
		TerraformDir: "/tf",
		ConfigPath:   "/tmp/c.yaml",
		Provider:     config.ProviderGKE,
		State:        config.StateLocal,
		Runner:       m,
	})
	if err != nil {
		t.Fatalf("Output() error: %v", err)
	}
	if string(data) != `{"key":"val"}` {
		t.Errorf("output = %q, want '{\"key\":\"val\"}'", data)
	}
	if len(m.calls) != 2 {
		t.Fatalf("got %d calls, want 2", len(m.calls))
	}
	if m.cmdString(1) != "terraform output -json" {
		t.Errorf("call[1] = %q, want 'terraform output -json'", m.cmdString(1))
	}
}

func TestOutputEmptyDir(t *testing.T) {
	_, err := Output(context.Background(), RunConfig{})
	if err == nil || !strings.Contains(err.Error(), "terraform dir is required") {
		t.Errorf("Output() error = %v, want 'terraform dir is required'", err)
	}
}

func TestRunEmptyDir(t *testing.T) {
	err := Run(context.Background(), RunConfig{})
	if err == nil || !strings.Contains(err.Error(), "terraform dir is required") {
		t.Errorf("Run() error = %v, want 'terraform dir is required'", err)
	}
}

func TestImportIfMissingSkipsExisting(t *testing.T) {
	m := &mockRunner{cmdOutput: "google_kms_key_ring.gke[0]\n"}
	cfg := RunConfig{
		TerraformDir: "/tf",
		Provider:     config.ProviderGKE,
		State:        config.StateLocal,
		ImportTargets: []ImportTarget{
			{Address: "google_kms_key_ring.gke[0]", ID: "projects/p/locations/r/keyRings/kr"},
		},
		Runner: m,
	}
	importIfMissing(context.Background(), cfg, nil)
	// Only state list call, no import call
	if len(m.calls) != 1 {
		t.Fatalf("got %d calls, want 1 (state list only)", len(m.calls))
	}
}

func TestImportIfMissingImportsNew(t *testing.T) {
	m := &mockRunner{cmdOutput: ""}
	cfg := RunConfig{
		TerraformDir: "/tf",
		Provider:     config.ProviderGKE,
		State:        config.StateLocal,
		ImportTargets: []ImportTarget{
			{Address: "google_kms_key_ring.gke[0]", ID: "projects/p/locations/r/keyRings/kr"},
		},
		Runner: m,
	}
	importIfMissing(context.Background(), cfg, nil)
	if len(m.calls) != 2 {
		t.Fatalf("got %d calls, want 2 (state list + import)", len(m.calls))
	}
	if m.cmdString(1) != "terraform import google_kms_key_ring.gke[0] projects/p/locations/r/keyRings/kr" {
		t.Errorf("call[1] = %q", m.cmdString(1))
	}
}
