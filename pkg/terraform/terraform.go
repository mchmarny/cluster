package terraform

import (
	"context"
	"fmt"
	"log/slog"
	"strings"

	"github.com/mchmarny/cluster/pkg/config"
	"github.com/mchmarny/cluster/pkg/run"
)

const (
	envTFAutomation = "TF_IN_AUTOMATION=1"
	cmdInit         = "init"
)

// RunConfig holds all parameters for a Terraform run.
type RunConfig struct {
	TerraformDir string
	ConfigPath   string
	Provider     string // config.ProviderEKS, ProviderGKE, ProviderAKS, or ProviderOKE
	State        string // config.StateTenancy or config.StateLocal
	Bucket       string
	Region       string
	StateKey     string
	Destroy      bool

	// AWS credentials passed explicitly (not via os.Setenv). OKE reuses these
	// for the s3 backend against OCI's S3-compatibility endpoint.
	AccessKeyID     string
	SecretAccessKey string

	// GCP credentials file path (written from KEY_CONTENT).
	CredentialsFile string

	// Azure state backend coordinates (azurerm backend).
	ResourceGroup  string
	StorageAccount string
	Container      string

	// OCI s3-compatible backend endpoint (Object Storage S3 compatibility).
	S3Endpoint string

	// ImportTargets lists resources to import if missing from state.
	// Each entry maps a Terraform resource address to its provider ID.
	ImportTargets []ImportTarget

	// Runner executes external commands. If nil, uses run.DefaultRunner.
	Runner run.Runner
}

// ImportTarget represents a resource to import if not already in state.
type ImportTarget struct {
	Address string // e.g. "google_kms_key_ring.gke[0]"
	ID      string // e.g. "projects/my-proj/locations/us-central1/keyRings/my-keyring"
}

func runner(cfg RunConfig) run.Runner {
	if cfg.Runner != nil {
		return cfg.Runner
	}
	return run.DefaultRunner{}
}

// Output runs terraform init and captures terraform output -json.
func Output(ctx context.Context, cfg RunConfig) ([]byte, error) {
	if cfg.TerraformDir == "" {
		return nil, fmt.Errorf("terraform dir is required")
	}

	slog.Info("terraform output", "dir", cfg.TerraformDir, "state", cfg.State)

	r := runner(cfg)
	env := buildEnv(cfg)

	initArgs := buildInitArgs(cfg)
	if err := r.CmdStream(ctx, cfg.TerraformDir, env, "terraform", initArgs...); err != nil {
		return nil, fmt.Errorf("terraform init: %w", err)
	}

	out, err := r.Cmd(ctx, cfg.TerraformDir, env, "terraform", "output", "-json")
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

	r := runner(cfg)
	env := buildEnv(cfg)

	initArgs := buildInitArgs(cfg)
	if err := r.CmdStream(ctx, cfg.TerraformDir, env, "terraform", initArgs...); err != nil {
		return fmt.Errorf("terraform init: %w", err)
	}

	if err := r.CmdStream(ctx, cfg.TerraformDir, env, "terraform", "plan"); err != nil {
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

	r := runner(cfg)
	env := buildEnv(cfg)

	// Init
	initArgs := buildInitArgs(cfg)
	if err := r.CmdStream(ctx, cfg.TerraformDir, env, "terraform", initArgs...); err != nil {
		return fmt.Errorf("terraform init: %w", err)
	}

	// Import resources that may exist outside state (e.g. GCP KMS KeyRings
	// which cannot be deleted and persist across destroy/recreate cycles).
	importIfMissing(ctx, cfg, env)

	if cfg.Destroy {
		slog.Info("refreshing state before destroy")
		if err := r.CmdStream(ctx, cfg.TerraformDir, env, "terraform", "refresh"); err != nil {
			return fmt.Errorf("terraform refresh: %w", err)
		}

		slog.Info("destroying infrastructure")
		if err := r.CmdStream(ctx, cfg.TerraformDir, env, "terraform", "destroy", "-auto-approve"); err != nil {
			return fmt.Errorf("terraform destroy: %w", err)
		}
		return nil
	}

	slog.Info("planning deployment")
	if err := r.CmdStream(ctx, cfg.TerraformDir, env, "terraform", "plan", "-out=plan.cache"); err != nil {
		return fmt.Errorf("terraform plan: %w", err)
	}

	slog.Info("applying deployment")
	if err := r.CmdStream(ctx, cfg.TerraformDir, env, "terraform", "apply", "plan.cache"); err != nil {
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

	r := runner(cfg)

	out, err := r.Cmd(ctx, cfg.TerraformDir, env, "terraform", "state", "list")
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
		if err := r.CmdStream(ctx, cfg.TerraformDir, env, "terraform", "import", t.Address, t.ID); err != nil {
			slog.Warn("import failed (resource may not exist yet)", "address", t.Address, "error", err)
		}
	}
}

func buildEnv(cfg RunConfig) []string {
	env := []string{
		fmt.Sprintf("TF_VAR_CONFIG_PATH=%s", cfg.ConfigPath),
		envTFAutomation,
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
	case config.ProviderAKS:
		// azurerm authenticates via ARM_* env vars (service principal) or the
		// Azure CLI default chain; both are inherited from the process env and
		// not owned by this tool, so no per-run env vars are injected here.
	case config.ProviderOKE:
		// OKE uses the s3 backend against OCI Object Storage. The Terraform oci
		// provider authenticates via OCI_* env / config file (inherited); the
		// s3 backend uses AWS-style keys mapped to OCI Customer Secret Keys.
		if cfg.AccessKeyID != "" {
			env = append(env, fmt.Sprintf("AWS_ACCESS_KEY_ID=%s", cfg.AccessKeyID))
		}
		if cfg.SecretAccessKey != "" {
			env = append(env, fmt.Sprintf("AWS_SECRET_ACCESS_KEY=%s", cfg.SecretAccessKey))
		}
	}

	return env
}

func buildInitArgs(cfg RunConfig) []string {
	args := []string{cmdInit}

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
	case config.ProviderAKS:
		args = append(args,
			fmt.Sprintf("-backend-config=resource_group_name=%s", cfg.ResourceGroup),
			fmt.Sprintf("-backend-config=storage_account_name=%s", cfg.StorageAccount),
			fmt.Sprintf("-backend-config=container_name=%s", cfg.Container),
			fmt.Sprintf("-backend-config=key=%s", cfg.StateKey),
		)
	case config.ProviderOKE:
		// s3 backend against OCI Object Storage's S3-compatibility endpoint.
		args = append(args,
			fmt.Sprintf("-backend-config=bucket=%s", cfg.Bucket),
			fmt.Sprintf("-backend-config=key=%s", cfg.StateKey),
			fmt.Sprintf("-backend-config=region=%s", cfg.Region),
		)
		if cfg.S3Endpoint != "" {
			args = append(args,
				fmt.Sprintf("-backend-config=endpoints={s3=%q}", cfg.S3Endpoint),
			)
		}
	}

	return args
}
