package state

import (
	"encoding/base64"
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

func TestParseKeyContent(t *testing.T) {
	keyJSON := `{"AccessKey":{"AccessKeyId":"AKIAROUND","SecretAccessKey":"roundtrip","UserName":"test"}}`
	encoded := base64.StdEncoding.EncodeToString([]byte(keyJSON))

	keyID, secret, err := ParseKeyContent(encoded)
	if err != nil {
		t.Fatalf("ParseKeyContent() error: %v", err)
	}
	if keyID != "AKIAROUND" {
		t.Errorf("AccessKeyId = %q, want %q", keyID, "AKIAROUND")
	}
	if secret != "roundtrip" {
		t.Errorf("SecretAccessKey = %q, want %q", secret, "roundtrip")
	}
}

func TestParseKeyContentInvalidBase64(t *testing.T) {
	_, _, err := ParseKeyContent("not-valid-base64!!!")
	if err == nil {
		t.Error("expected error for invalid base64")
	}
}

func TestParseKeyContentInvalidJSON(t *testing.T) {
	encoded := base64.StdEncoding.EncodeToString([]byte("not json"))
	_, _, err := ParseKeyContent(encoded)
	if err == nil {
		t.Error("expected error for invalid JSON")
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
