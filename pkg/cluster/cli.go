package cluster

import (
	"context"
	"fmt"
	"log/slog"
	"os"

	"github.com/urfave/cli/v3"

	"github.com/mchmarny/cluster/pkg/aws"
	"github.com/mchmarny/cluster/pkg/config"
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

func applyCmd() *cli.Command {
	return &cli.Command{
		Name:  "apply",
		Usage: "Deploy or destroy infrastructure via Terraform",
		Flags: append(configFlags(),
			&cli.StringFlag{
				Name:    "terraform-dir",
				Usage:   "Terraform working directory",
				Value:   "/builder/terraform",
				Sources: cli.EnvVars("TERRAFORM_DIR"),
			},
		),
		Action: func(ctx context.Context, cmd *cli.Command) error {
			cfg, configPath, err := loadConfig(cmd)
			if err != nil {
				return err
			}

			sd := cmd.String("state-dir")
			tfDir := cmd.String("terraform-dir")
			kc := cmd.String("key-content")

			keyID, secret := resolveCredentials(kc, sd, cfg)

			return terraform.Run(ctx, terraform.RunConfig{
				TerraformDir:    tfDir,
				ConfigPath:      configPath,
				State:           cfg.Deployment.State,
				Bucket:          aws.BucketName(cfg),
				Region:          cfg.Deployment.Location,
				StateKey:        aws.StateKey(cfg),
				Destroy:         cfg.Deployment.Destroy,
				AccessKeyID:     keyID,
				SecretAccessKey: secret,
			})
		},
	}
}

func outputCmd() *cli.Command {
	return &cli.Command{
		Name:  "output",
		Usage: "Retrieve Terraform outputs and save to state directory",
		Flags: append(configFlags(),
			&cli.StringFlag{
				Name:    "terraform-dir",
				Usage:   "Terraform working directory",
				Value:   "/builder/terraform",
				Sources: cli.EnvVars("TERRAFORM_DIR"),
			},
		),
		Action: func(ctx context.Context, cmd *cli.Command) error {
			cfg, configPath, err := loadConfig(cmd)
			if err != nil {
				return err
			}

			sd := cmd.String("state-dir")
			tfDir := cmd.String("terraform-dir")
			kc := cmd.String("key-content")

			keyID, secret := resolveCredentials(kc, sd, cfg)

			data, err := terraform.Output(ctx, terraform.RunConfig{
				TerraformDir:    tfDir,
				ConfigPath:      configPath,
				State:           cfg.Deployment.State,
				Bucket:          aws.BucketName(cfg),
				Region:          cfg.Deployment.Location,
				StateKey:        aws.StateKey(cfg),
				AccessKeyID:     keyID,
				SecretAccessKey: secret,
			})
			if err != nil {
				return err
			}

			outFile := aws.OutputFileName(cfg)
			if err := state.WriteFile(sd, outFile, data); err != nil {
				return fmt.Errorf("saving output: %w", err)
			}

			fmt.Fprintf(os.Stderr, "Output saved to %s/%s\n", sd, outFile)
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
			Usage:   "Base64-encoded AWS key JSON (from setup)",
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

// loadConfig resolves and loads the YAML config. Returns the loaded config,
// the resolved file path (for passing to terraform), and any error.
func loadConfig(cmd *cli.Command) (*config.Config, string, error) {
	configPath, cleanup, err := config.Resolve(
		cmd.String("config"),
		cmd.String("config-content"),
	)
	if err != nil {
		return nil, "", fmt.Errorf("resolving config: %w", err)
	}
	// Note: cleanup deferred by caller or at process exit.
	// In a CLI context, the temp file lives for the process lifetime.
	_ = cleanup

	cfg, err := config.Load(configPath)
	if err != nil {
		return nil, "", fmt.Errorf("loading config: %w", err)
	}

	return cfg, configPath, nil
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
