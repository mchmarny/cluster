package config

import (
	"encoding/base64"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
)

// Resolve returns a path to a config YAML file and a cleanup function.
// The cleanup function removes any temp files created during resolution.
// Priority:
// 1. configPath (explicit file path)
// 2. configContent (base64-encoded YAML, written to temp file)
func Resolve(configPath, configContent string) (path string, cleanup func(), err error) {
	noop := func() {}

	if configPath != "" {
		if _, err := os.Stat(configPath); err != nil {
			return "", noop, fmt.Errorf("config file not found: %s", configPath)
		}
		slog.Info("config source: file", "path", configPath)
		return configPath, noop, nil
	}

	if configContent != "" {
		data, err := base64.StdEncoding.DecodeString(configContent)
		if err != nil {
			return "", noop, fmt.Errorf("invalid base64 config content: %w", err)
		}

		dir, err := os.MkdirTemp("", "cluster-config-*")
		if err != nil {
			return "", noop, fmt.Errorf("creating temp dir: %w", err)
		}

		p := filepath.Join(dir, "config.yaml")
		if err := os.WriteFile(p, data, 0600); err != nil {
			os.RemoveAll(dir)
			return "", noop, fmt.Errorf("writing config: %w", err)
		}

		slog.Info("config source: base64 content", "path", p)
		return p, func() { os.RemoveAll(dir) }, nil
	}

	return "", noop, fmt.Errorf("no config provided: set CONFIG_PATH or CONFIG_CONTENT")
}
