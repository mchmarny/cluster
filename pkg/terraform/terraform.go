package terraform

import (
	"context"
	"fmt"
	"log/slog"

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

func buildEnv(cfg RunConfig) []string {
	env := []string{
		fmt.Sprintf("TF_VAR_CONFIG_PATH=%s", cfg.ConfigPath),
		"TF_IN_AUTOMATION=1",
	}

	if cfg.Provider == config.ProviderEKS {
		if cfg.AccessKeyID != "" {
			env = append(env, fmt.Sprintf("AWS_ACCESS_KEY_ID=%s", cfg.AccessKeyID))
		}
		if cfg.SecretAccessKey != "" {
			env = append(env, fmt.Sprintf("AWS_SECRET_ACCESS_KEY=%s", cfg.SecretAccessKey))
		}
		if cfg.Region != "" {
			env = append(env, fmt.Sprintf("AWS_DEFAULT_REGION=%s", cfg.Region))
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
