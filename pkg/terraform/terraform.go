package terraform

import (
	"context"
	"fmt"
	"log/slog"
	"strings"

	"github.com/mchmarny/cluster/pkg/config"
	"github.com/mchmarny/cluster/pkg/run"
)

// RunConfig holds all parameters for a Terraform run.
type RunConfig struct {
	TerraformDir string
	ConfigPath   string
	Provider     string // config.ProviderEKS or config.ProviderGKE
	State        string // config.StateTenancy or config.StateLocal
	Bucket       string
	Region       string
	StateKey     string
	Destroy      bool

	// AWS credentials passed explicitly (not via os.Setenv).
	AccessKeyID     string
	SecretAccessKey string

	// GCP credentials file path (written from KEY_CONTENT).
	CredentialsFile string

	// ImportTargets lists resources to import if missing from state.
	// Each entry maps a Terraform resource address to its provider ID.
	ImportTargets []ImportTarget
}

// ImportTarget represents a resource to import if not already in state.
type ImportTarget struct {
	Address string // e.g. "google_kms_key_ring.gke[0]"
	ID      string // e.g. "projects/my-proj/locations/us-central1/keyRings/my-keyring"
}

// Output runs terraform init and captures terraform output -json.
func Output(ctx context.Context, cfg RunConfig) ([]byte, error) {
	if cfg.TerraformDir == "" {
		return nil, fmt.Errorf("terraform dir is required")
	}

	slog.Info("terraform output", "dir", cfg.TerraformDir, "state", cfg.State)

	env := buildEnv(cfg)

	initArgs := buildInitArgs(cfg)
	if err := run.CmdStream(ctx, cfg.TerraformDir, env, "terraform", initArgs...); err != nil {
		return nil, fmt.Errorf("terraform init: %w", err)
	}

	out, err := run.Cmd(ctx, cfg.TerraformDir, env, "terraform", "output", "-json")
	if err != nil {
		return nil, fmt.Errorf("terraform output: %w", err)
	}

	return []byte(out), nil
}

// Plan runs terraform init and plan, streaming output without applying.
func Plan(ctx context.Context, cfg RunConfig) error {
	if cfg.TerraformDir == "" {
		return fmt.Errorf("terraform dir is required")
	}

	slog.Info("terraform plan", "dir", cfg.TerraformDir, "state", cfg.State,
		"configPath", cfg.ConfigPath)

	env := buildEnv(cfg)

	initArgs := buildInitArgs(cfg)
	if err := run.CmdStream(ctx, cfg.TerraformDir, env, "terraform", initArgs...); err != nil {
		return fmt.Errorf("terraform init: %w", err)
	}

	if err := run.CmdStream(ctx, cfg.TerraformDir, env, "terraform", "plan"); err != nil {
		return fmt.Errorf("terraform plan: %w", err)
	}

	return nil
}

// Run orchestrates the full Terraform lifecycle.
func Run(ctx context.Context, cfg RunConfig) error {
	if cfg.TerraformDir == "" {
		return fmt.Errorf("terraform dir is required")
	}

	slog.Info("terraform", "dir", cfg.TerraformDir, "state", cfg.State,
		"destroy", cfg.Destroy, "configPath", cfg.ConfigPath)

	env := buildEnv(cfg)

	// Init
	initArgs := buildInitArgs(cfg)
	if err := run.CmdStream(ctx, cfg.TerraformDir, env, "terraform", initArgs...); err != nil {
		return fmt.Errorf("terraform init: %w", err)
	}

	// Import resources that may exist outside state (e.g. GCP KMS KeyRings
	// which cannot be deleted and persist across destroy/recreate cycles).
	importIfMissing(ctx, cfg, env)

	if cfg.Destroy {
		slog.Info("refreshing state before destroy")
		if err := run.CmdStream(ctx, cfg.TerraformDir, env, "terraform", "refresh"); err != nil {
			return fmt.Errorf("terraform refresh: %w", err)
		}

		slog.Info("destroying infrastructure")
		if err := run.CmdStream(ctx, cfg.TerraformDir, env, "terraform", "destroy", "-auto-approve"); err != nil {
			return fmt.Errorf("terraform destroy: %w", err)
		}
		return nil
	}

	slog.Info("planning deployment")
	if err := run.CmdStream(ctx, cfg.TerraformDir, env, "terraform", "plan", "-out=plan.cache"); err != nil {
		return fmt.Errorf("terraform plan: %w", err)
	}

	slog.Info("applying deployment")
	if err := run.CmdStream(ctx, cfg.TerraformDir, env, "terraform", "apply", "plan.cache"); err != nil {
		return fmt.Errorf("terraform apply: %w", err)
	}

	return nil
}

// importIfMissing checks each ImportTarget and imports it if not already in state.
// All failures are logged but non-fatal — the resource may not exist yet (first deploy).
func importIfMissing(ctx context.Context, cfg RunConfig, env []string) {
	if len(cfg.ImportTargets) == 0 {
		return
	}

	out, err := run.Cmd(ctx, cfg.TerraformDir, env, "terraform", "state", "list")
	if err != nil {
		slog.Warn("terraform state list failed, skipping import check", "error", err)
		return
	}

	existing := make(map[string]bool)
	for _, line := range strings.Split(strings.TrimSpace(out), "\n") {
		existing[strings.TrimSpace(line)] = true
	}

	for _, t := range cfg.ImportTargets {
		if existing[t.Address] {
			slog.Info("resource already in state, skipping import", "address", t.Address)
			continue
		}
		slog.Info("importing resource into state", "address", t.Address, "id", t.ID)
		if err := run.CmdStream(ctx, cfg.TerraformDir, env, "terraform", "import", t.Address, t.ID); err != nil {
			slog.Warn("import failed (resource may not exist yet)", "address", t.Address, "error", err)
		}
	}
}

func buildEnv(cfg RunConfig) []string {
	env := []string{
		fmt.Sprintf("TF_VAR_CONFIG_PATH=%s", cfg.ConfigPath),
		"TF_IN_AUTOMATION=1",
	}

	switch cfg.Provider {
	case config.ProviderEKS:
		if cfg.AccessKeyID != "" {
			env = append(env, fmt.Sprintf("AWS_ACCESS_KEY_ID=%s", cfg.AccessKeyID))
		}
		if cfg.SecretAccessKey != "" {
			env = append(env, fmt.Sprintf("AWS_SECRET_ACCESS_KEY=%s", cfg.SecretAccessKey))
		}
		if cfg.Region != "" {
			env = append(env, fmt.Sprintf("AWS_DEFAULT_REGION=%s", cfg.Region))
		}
	case config.ProviderGKE:
		if cfg.CredentialsFile != "" {
			env = append(env, fmt.Sprintf("GOOGLE_APPLICATION_CREDENTIALS=%s", cfg.CredentialsFile))
		}
	}

	return env
}

func buildInitArgs(cfg RunConfig) []string {
	args := []string{"init"}

	if cfg.State != config.StateTenancy || cfg.Bucket == "" {
		return args
	}

	switch cfg.Provider {
	case config.ProviderEKS:
		args = append(args,
			fmt.Sprintf("-backend-config=bucket=%s", cfg.Bucket),
			fmt.Sprintf("-backend-config=region=%s", cfg.Region),
			"-backend-config=encrypt=true",
			fmt.Sprintf("-backend-config=key=%s", cfg.StateKey),
		)
	case config.ProviderGKE:
		args = append(args,
			fmt.Sprintf("-backend-config=bucket=%s", cfg.Bucket),
			fmt.Sprintf("-backend-config=prefix=%s", cfg.StateKey),
		)
	}

	return args
}
