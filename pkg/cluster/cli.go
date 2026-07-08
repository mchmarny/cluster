package cluster

import (
	"context"
	"encoding/base64"
	"fmt"
	"log/slog"
	"os"

	"github.com/urfave/cli/v3"

	"github.com/mchmarny/cluster/pkg/aws"
	"github.com/mchmarny/cluster/pkg/azure"
	"github.com/mchmarny/cluster/pkg/config"
	"github.com/mchmarny/cluster/pkg/gcp"
	"github.com/mchmarny/cluster/pkg/state"
	"github.com/mchmarny/cluster/pkg/terraform"
)

const (
	appName  = "cluster"
	stateDir = "/state"
)

func Execute(version, commit string) {
	// Default: suppress all structured logging. --debug enables it.
	logLevel := new(slog.LevelVar)
	logLevel.Set(slog.LevelError + 1) // above Error = silent
	slog.SetDefault(slog.New(slog.NewJSONHandler(os.Stderr, &slog.HandlerOptions{
		Level: logLevel,
	})))

	app := &cli.Command{
		Name:    appName,
		Version: fmt.Sprintf("%s (commit: %s)", version, commit),
		Usage:   "Self-contained cluster deployment tool",
		Flags: []cli.Flag{
			&cli.BoolFlag{
				Name:  "debug",
				Usage: "Enable debug logging",
			},
		},
		Before: func(ctx context.Context, cmd *cli.Command) (context.Context, error) {
			if cmd.Bool("debug") {
				logLevel.Set(slog.LevelDebug)
			}
			return ctx, nil
		},
		Commands: []*cli.Command{
			initCmd(),
			planCmd(),
			applyCmd(),
			outputCmd(),
		},
		Action: func(_ context.Context, cmd *cli.Command) error {
			return cli.ShowAppHelp(cmd)
		},
	}

	if err := app.Run(context.Background(), os.Args); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}

func initCmd() *cli.Command {
	return &cli.Command{
		Name:      "init",
		Usage:     "Generate a starter configuration file",
		ArgsUsage: "<output-path>",
		Action: func(_ context.Context, cmd *cli.Command) error {
			path := cmd.Args().First()
			if path == "" {
				return fmt.Errorf("usage: cluster init <output-path>")
			}

			if err := config.GenerateTemplate(path); err != nil {
				return err
			}

			slog.Info("config template generated", "path", path)
			fmt.Fprintf(os.Stderr, "Config written to %s\nEdit the REQUIRED fields, then run: provider/<csp>/tools/setup\n", path)
			return nil
		},
	}
}

func terraformFlags() []cli.Flag {
	return append(configFlags(),
		&cli.StringFlag{
			Name:    "terraform-dir",
			Usage:   "Terraform working directory",
			Value:   "/builder/terraform",
			Sources: cli.EnvVars("TERRAFORM_DIR"),
		},
	)
}

func applyCmd() *cli.Command {
	return &cli.Command{
		Name:  "apply",
		Usage: "Deploy or destroy infrastructure via Terraform",
		Flags: terraformFlags(),
		Action: func(ctx context.Context, cmd *cli.Command) error {
			rc, cleanup, err := buildRunConfig(cmd)
			if err != nil {
				return err
			}
			defer cleanup()

			rc.Destroy = rc.destroy
			rc.ImportTargets = rc.importTargets

			return terraform.Run(ctx, rc.RunConfig)
		},
	}
}

func planCmd() *cli.Command {
	return &cli.Command{
		Name:  "plan",
		Usage: "Validate configuration and display Terraform plan",
		Flags: terraformFlags(),
		Action: func(ctx context.Context, cmd *cli.Command) error {
			rc, cleanup, err := buildRunConfig(cmd)
			if err != nil {
				return err
			}
			defer cleanup()

			return terraform.Plan(ctx, rc.RunConfig)
		},
	}
}

func outputCmd() *cli.Command {
	return &cli.Command{
		Name:  "output",
		Usage: "Retrieve Terraform outputs and save to state directory",
		Flags: terraformFlags(),
		Action: func(ctx context.Context, cmd *cli.Command) error {
			rc, cleanup, err := buildRunConfig(cmd)
			if err != nil {
				return err
			}
			defer cleanup()

			data, err := terraform.Output(ctx, rc.RunConfig)
			if err != nil {
				return err
			}

			if err := state.WriteFile(rc.stateDir, rc.outputFile, data); err != nil {
				return fmt.Errorf("saving output: %w", err)
			}

			fmt.Fprintf(os.Stderr, "Output saved to %s/%s\n", rc.stateDir, rc.outputFile)
			return nil
		},
	}
}

func configFlags() []cli.Flag {
	return []cli.Flag{
		&cli.StringFlag{
			Name:    "config",
			Aliases: []string{"c"},
			Usage:   "Path to YAML configuration file",
			Sources: cli.EnvVars("CONFIG_PATH"),
		},
		&cli.StringFlag{
			Name:    "config-content",
			Usage:   "Base64-encoded YAML configuration",
			Sources: cli.EnvVars("CONFIG_CONTENT"),
		},
		&cli.StringFlag{
			Name:    "key-content",
			Usage:   "Base64-encoded credentials (AWS key JSON or GCP ADC JSON)",
			Sources: cli.EnvVars("KEY_CONTENT"),
		},
		&cli.StringFlag{
			Name:    "state-dir",
			Usage:   "Directory for state and key files",
			Value:   stateDir,
			Sources: cli.EnvVars("STATE_DIR"),
		},
	}
}

// runConfigResult bundles the terraform RunConfig with command-level metadata
// that individual commands may need (output file, state dir, etc.).
type runConfigResult struct {
	terraform.RunConfig
	stateDir      string
	outputFile    string
	destroy       bool
	importTargets []terraform.ImportTarget
}

// buildRunConfig loads config, resolves credentials, and assembles a RunConfig.
// Returns a cleanup function that removes any temp files (config, credentials).
func buildRunConfig(cmd *cli.Command) (*runConfigResult, func(), error) {
	noop := func() {}

	configPath, cfgCleanup, err := config.Resolve(
		cmd.String("config"),
		cmd.String("config-content"),
	)
	if err != nil {
		return nil, noop, fmt.Errorf("resolving config: %w", err)
	}

	cfg, err := config.Load(configPath)
	if err != nil {
		cfgCleanup()
		return nil, noop, fmt.Errorf("loading config: %w", err)
	}

	sd := cmd.String("state-dir")
	tfDir := cmd.String("terraform-dir")
	kc := cmd.String("key-content")

	rc := &runConfigResult{
		RunConfig: terraform.RunConfig{
			TerraformDir: tfDir,
			ConfigPath:   configPath,
			Provider:     cfg.Deployment.Provider,
			State:        cfg.Deployment.State,
			Region:       cfg.Deployment.Location,
			Destroy:      cfg.Deployment.Destroy,
		},
		stateDir: sd,
		destroy:  cfg.Deployment.Destroy,
	}

	cleanup := cfgCleanup

	switch cfg.Deployment.Provider {
	case config.ProviderEKS:
		keyID, secret := resolveCredentials(kc, sd, cfg)
		rc.Bucket = aws.BucketName(cfg)
		rc.StateKey = aws.StateKey(cfg)
		rc.AccessKeyID = keyID
		rc.SecretAccessKey = secret
		rc.outputFile = aws.OutputFileName(cfg)
	case config.ProviderGKE:
		rc.Bucket = gcp.BucketName(cfg)
		rc.StateKey = gcp.StatePrefix(cfg)
		rc.outputFile = gcp.OutputFileName(cfg)
		credFile, credCleanup, err := resolveGCPCredentials(kc)
		if err != nil {
			cfgCleanup()
			return nil, noop, err
		}
		rc.CredentialsFile = credFile
		rc.importTargets = gkeImportTargets(cfg)
		cleanup = func() { credCleanup(); cfgCleanup() }
	case config.ProviderAKS:
		rc.Bucket = azure.BucketName(cfg)
		rc.StorageAccount = azure.StorageAccountName(cfg)
		rc.ResourceGroup = azure.ResourceGroupName(cfg)
		rc.Container = azure.ContainerName(cfg)
		rc.StateKey = azure.StateKey(cfg)
		rc.outputFile = azure.OutputFileName(cfg)
		// azurerm authenticates via ARM_* env / az CLI default chain, inherited
		// from the process environment.
		logAzureCredentials()
	default:
		cfgCleanup()
		return nil, noop, fmt.Errorf("unsupported provider: %s", cfg.Deployment.Provider)
	}

	return rc, cleanup, nil
}

// gkeImportTargets returns resources that may exist outside Terraform state.
// GCP KMS KeyRings cannot be deleted, so after a destroy/recreate cycle the
// KeyRing persists in GCP but is absent from state, causing a 409 on create.
func gkeImportTargets(cfg *config.Config) []terraform.ImportTarget {
	prefix := cfg.Deployment.ID
	project := cfg.Deployment.Tenancy
	region := cfg.Deployment.Location

	return []terraform.ImportTarget{
		{
			Address: "google_kms_key_ring.gke[0]",
			ID:      fmt.Sprintf("projects/%s/locations/%s/keyRings/%s-gke-keyring", project, region, prefix),
		},
	}
}

// resolveGCPCredentials decodes base64 KEY_CONTENT to a temp file and returns
// the file path, a cleanup function, and any error.
func resolveGCPCredentials(keyContent string) (string, func(), error) {
	noop := func() {}

	if keyContent == "" {
		if p := os.Getenv("GOOGLE_APPLICATION_CREDENTIALS"); p != "" {
			slog.Info("using GCP credentials from GOOGLE_APPLICATION_CREDENTIALS")
			return p, noop, nil
		}
		slog.Info("no GCP credentials provided, terraform will use default provider chain")
		return "", noop, nil
	}

	data, err := base64.StdEncoding.DecodeString(keyContent)
	if err != nil {
		return "", noop, fmt.Errorf("decoding KEY_CONTENT: %w", err)
	}

	f, err := os.CreateTemp("", "gcp-credentials-*.json")
	if err != nil {
		return "", noop, fmt.Errorf("creating credentials temp file: %w", err)
	}
	tmpPath := f.Name() // capture safe path from CreateTemp immediately

	if _, err := f.Write(data); err != nil {
		f.Close()
		os.Remove(tmpPath) //nolint:gosec // tmpPath is from os.CreateTemp, not user input
		return "", noop, fmt.Errorf("writing credentials: %w", err)
	}

	if err := f.Close(); err != nil {
		os.Remove(tmpPath) //nolint:gosec // tmpPath is from os.CreateTemp, not user input
		return "", noop, fmt.Errorf("closing credentials file: %w", err)
	}

	slog.Info("using GCP credentials from KEY_CONTENT", "path", tmpPath)
	return tmpPath, func() { os.Remove(tmpPath) }, nil //nolint:gosec // tmpPath is from os.CreateTemp
}

// logAzureCredentials reports which Azure authentication source terraform will
// use. The azurerm provider reads ARM_* env vars (service principal) or falls
// back to the Azure CLI default chain; this tool does not own those secrets, it
// only surfaces which path is active for operator visibility.
func logAzureCredentials() {
	if os.Getenv("ARM_CLIENT_ID") != "" && os.Getenv("ARM_CLIENT_SECRET") != "" {
		slog.Info("using Azure credentials from ARM_* service principal environment")
		return
	}
	slog.Info("no ARM_* service principal set, terraform will use the Azure CLI default chain")
}

// resolveCredentials returns AWS credentials using the following priority:
//  1. KEY_CONTENT (base64-encoded key JSON)
//  2. AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY env vars
//  3. State key file on disk
//  4. Empty (terraform uses default provider chain)
func resolveCredentials(keyContent, stateDir string, cfg *config.Config) (keyID, secret string) {
	if keyContent != "" {
		id, s, err := state.ParseKeyContent(keyContent)
		if err != nil {
			slog.Warn("failed to parse KEY_CONTENT", "error", err)
		} else {
			slog.Info("using AWS credentials from KEY_CONTENT")
			return id, s
		}
	}

	if id, s := os.Getenv("AWS_ACCESS_KEY_ID"), os.Getenv("AWS_SECRET_ACCESS_KEY"); id != "" && s != "" {
		slog.Info("using AWS credentials from environment")
		return id, s
	}

	id, s, err := state.ReadKey(stateDir, aws.KeyFileName(cfg))
	if err != nil {
		slog.Warn("no stored credentials found, terraform will use default provider chain")
		return "", ""
	}

	slog.Info("using AWS credentials from state key file")
	return id, s
}
