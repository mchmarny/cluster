package state

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

type accessKeyResponse struct {
	AccessKey struct {
		AccessKeyId     string `json:"AccessKeyId"` //nolint:revive // AWS JSON key
		SecretAccessKey string `json:"SecretAccessKey"`
		UserName        string `json:"UserName"`
	} `json:"AccessKey"`
}

// WriteKey writes a raw key JSON (from aws iam create-access-key) to the state dir.
func WriteKey(stateDir, fileName string, data []byte) error {
	path, err := safePath(stateDir, fileName)
	if err != nil {
		return err
	}

	if err := os.MkdirAll(stateDir, 0755); err != nil {
		return fmt.Errorf("creating state dir: %w", err)
	}

	if err := os.WriteFile(path, data, 0600); err != nil {
		return fmt.Errorf("writing key file: %w", err)
	}

	return nil
}

// ReadKey reads a key file from the state dir and returns (AccessKeyId, SecretAccessKey).
func ReadKey(stateDir, fileName string) (string, string, error) {
	path, err := safePath(stateDir, fileName)
	if err != nil {
		return "", "", err
	}

	data, err := os.ReadFile(path)
	if err != nil {
		return "", "", fmt.Errorf("reading key file %s: %w (run 'setup' first)", path, err)
	}

	return parseKey(data)
}

// ParseKeyContent decodes a base64-encoded key JSON and returns (AccessKeyId, SecretAccessKey).
func ParseKeyContent(base64Content string) (string, string, error) {
	data, err := base64.StdEncoding.DecodeString(base64Content)
	if err != nil {
		return "", "", fmt.Errorf("decoding base64 key content: %w", err)
	}
	return parseKey(data)
}

// parseKey parses raw key JSON (from aws iam create-access-key) and returns credentials.
func parseKey(data []byte) (string, string, error) {
	var resp accessKeyResponse
	if err := json.Unmarshal(data, &resp); err != nil {
		return "", "", fmt.Errorf("parsing key file: %w", err)
	}

	if resp.AccessKey.AccessKeyId == "" || resp.AccessKey.SecretAccessKey == "" {
		return "", "", fmt.Errorf("key data missing AccessKeyId or SecretAccessKey")
	}

	return resp.AccessKey.AccessKeyId, resp.AccessKey.SecretAccessKey, nil
}

// WriteFile writes arbitrary data to the state dir.
func WriteFile(stateDir, fileName string, data []byte) error {
	path, err := safePath(stateDir, fileName)
	if err != nil {
		return err
	}

	if err := os.MkdirAll(stateDir, 0755); err != nil {
		return fmt.Errorf("creating state dir: %w", err)
	}

	if err := os.WriteFile(path, data, 0600); err != nil {
		return fmt.Errorf("writing file: %w", err)
	}

	return nil
}

// safePath validates that the resolved path stays within stateDir.
func safePath(stateDir, fileName string) (string, error) {
	absDir, err := filepath.Abs(stateDir)
	if err != nil {
		return "", fmt.Errorf("resolving state dir: %w", err)
	}

	joined := filepath.Join(absDir, fileName)
	resolved := filepath.Clean(joined)

	if !strings.HasPrefix(resolved, absDir+string(filepath.Separator)) && resolved != absDir {
		return "", fmt.Errorf("path traversal blocked: %q escapes state dir %q", fileName, stateDir)
	}

	return resolved, nil
}
