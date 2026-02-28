package state

import (
	"os"
	"path/filepath"
	"testing"
)

func TestWriteAndReadKey(t *testing.T) {
	dir := t.TempDir()
	name := "test-key.json"

	keyJSON := []byte(`{"AccessKey":{"AccessKeyId":"AKIATEST","SecretAccessKey":"secret123","UserName":"test-sa"}}`)

	if err := WriteKey(dir, name, keyJSON); err != nil {
		t.Fatalf("WriteKey() error: %v", err)
	}

	keyID, secret, err := ReadKey(dir, name)
	if err != nil {
		t.Fatalf("ReadKey() error: %v", err)
	}

	if keyID != "AKIATEST" {
		t.Errorf("AccessKeyId = %q, want %q", keyID, "AKIATEST")
	}
	if secret != "secret123" {
		t.Errorf("SecretAccessKey = %q, want %q", secret, "secret123")
	}

	info, _ := os.Stat(filepath.Join(dir, name))
	if info.Mode().Perm() != 0600 {
		t.Errorf("permissions = %o, want 0600", info.Mode().Perm())
	}
}

func TestReadKeyNotFound(t *testing.T) {
	_, _, err := ReadKey(t.TempDir(), "missing.json")
	if err == nil {
		t.Error("expected error for missing key file")
	}
}

func TestPathTraversal(t *testing.T) {
	dir := t.TempDir()

	if err := WriteKey(dir, "../escape.json", []byte("bad")); err == nil {
		t.Error("expected error for path traversal, got nil")
	}

	if err := WriteKey(dir, "../../etc/passwd", []byte("bad")); err == nil {
		t.Error("expected error for path traversal, got nil")
	}

	_, _, err := ReadKey(dir, "../escape.json")
	if err == nil {
		t.Error("expected error for path traversal read, got nil")
	}
}
