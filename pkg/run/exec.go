package run

import (
	"bytes"
	"context"
	"fmt"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

const gracefulTimeout = 10 * time.Second

// Runner executes external commands. Use the default implementation for
// production and inject a mock for unit tests.
type Runner interface {
	Cmd(ctx context.Context, dir string, env []string, name string, args ...string) (string, error)
	CmdStream(ctx context.Context, dir string, env []string, name string, args ...string) error
}

// DefaultRunner executes real commands via os/exec.
type DefaultRunner struct{}

func (DefaultRunner) Cmd(ctx context.Context, dir string, env []string, name string, args ...string) (string, error) {
	slog.Debug("exec", "cmd", name, "args", strings.Join(args, " "))

	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Cancel = func() error {
		return cmd.Process.Signal(syscall.SIGTERM)
	}
	cmd.WaitDelay = gracefulTimeout

	if dir != "" {
		cmd.Dir = dir
	}
	if len(env) > 0 {
		cmd.Env = append(os.Environ(), env...)
	}

	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		return "", fmt.Errorf("%s %s: %w\nstderr: %s", name, strings.Join(args, " "), err, stderr.String())
	}

	return stdout.String(), nil
}

func (DefaultRunner) CmdStream(ctx context.Context, dir string, env []string, name string, args ...string) error {
	slog.Debug("exec", "cmd", name, "args", strings.Join(args, " "))

	cmd := exec.CommandContext(ctx, name, args...)
	cmd.Cancel = func() error {
		return cmd.Process.Signal(syscall.SIGTERM)
	}
	cmd.WaitDelay = gracefulTimeout

	if dir != "" {
		cmd.Dir = dir
	}
	if len(env) > 0 {
		cmd.Env = append(os.Environ(), env...)
	}

	cmd.Stdout = os.Stdout
	cmd.Stderr = os.Stderr

	if err := cmd.Run(); err != nil {
		return fmt.Errorf("%s %s: %w", name, strings.Join(args, " "), err)
	}

	return nil
}

// Package-level functions using DefaultRunner.

func Cmd(ctx context.Context, dir string, env []string, name string, args ...string) (string, error) {
	return DefaultRunner{}.Cmd(ctx, dir, env, name, args...)
}

func CmdStream(ctx context.Context, dir string, env []string, name string, args ...string) error {
	return DefaultRunner{}.CmdStream(ctx, dir, env, name, args...)
}
