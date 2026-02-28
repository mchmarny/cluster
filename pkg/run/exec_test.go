package run

import (
	"context"
	"strings"
	"testing"
)

func TestCmd(t *testing.T) {
	out, err := Cmd(context.Background(), "", nil, "echo", "hello")
	if err != nil {
		t.Fatalf("Cmd() error: %v", err)
	}
	if got := strings.TrimSpace(out); got != "hello" {
		t.Errorf("Cmd() output = %q, want %q", got, "hello")
	}
}

func TestCmdFailure(t *testing.T) {
	_, err := Cmd(context.Background(), "", nil, "false")
	if err == nil {
		t.Error("expected error for failing command")
	}
}

func TestCmdWithEnv(t *testing.T) {
	env := []string{"TEST_VAR=hello_world"}
	out, err := Cmd(context.Background(), "", env, "sh", "-c", "echo $TEST_VAR")
	if err != nil {
		t.Fatalf("Cmd() error: %v", err)
	}
	if got := strings.TrimSpace(out); got != "hello_world" {
		t.Errorf("Cmd() output = %q, want %q", got, "hello_world")
	}
}

func TestCmdStreaming(t *testing.T) {
	err := CmdStream(context.Background(), "", nil, "echo", "streaming")
	if err != nil {
		t.Fatalf("CmdStream() error: %v", err)
	}
}
