package aws

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"sort"

	"github.com/mchmarny/cluster/pkg/run"
)

const builderPolicy = `{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "ec2:*",
      "autoscaling:*",
      "eks:*",
      "iam:*",
      "logs:*",
      "s3:*",
      "kms:*"
    ],
    "Resource": "*"
  }]
}`

type policyVersionsResponse struct {
	Versions []struct {
		VersionId        string `json:"VersionId"` //nolint:revive // AWS JSON key
		IsDefaultVersion bool   `json:"IsDefaultVersion"`
		CreateDate       string `json:"CreateDate"`
	} `json:"Versions"`
}

type accessKeysResponse struct {
	AccessKeyMetadata []struct {
		AccessKeyId string `json:"AccessKeyId"` //nolint:revive // AWS JSON key
	} `json:"AccessKeyMetadata"`
}

func parseOldestNonDefaultVersion(data []byte) (string, int, error) {
	var resp policyVersionsResponse
	if err := json.Unmarshal(data, &resp); err != nil {
		return "", 0, fmt.Errorf("parsing policy versions: %w", err)
	}

	var nonDefault []struct {
		id   string
		date string
	}
	for _, v := range resp.Versions {
		if !v.IsDefaultVersion {
			nonDefault = append(nonDefault, struct {
				id   string
				date string
			}{v.VersionId, v.CreateDate})
		}
	}

	if len(nonDefault) == 0 {
		return "", len(resp.Versions), nil
	}

	sort.Slice(nonDefault, func(i, j int) bool {
		return nonDefault[i].date < nonDefault[j].date
	})

	return nonDefault[0].id, len(resp.Versions), nil
}

func parseAccessKeyIDs(data []byte) ([]string, error) {
	var resp accessKeysResponse
	if err := json.Unmarshal(data, &resp); err != nil {
		return nil, fmt.Errorf("parsing access keys: %w", err)
	}

	ids := make([]string, len(resp.AccessKeyMetadata))
	for i, k := range resp.AccessKeyMetadata {
		ids[i] = k.AccessKeyId
	}
	return ids, nil
}

// EnsureIAMUser creates or updates the IAM user, policy, and access key.
// Returns the raw JSON from `aws iam create-access-key`.
func EnsureIAMUser(ctx context.Context, userName, policyName, policyARN string) ([]byte, error) {
	slog.Info("ensuring IAM user", "user", userName, "policy", policyName)

	// Create user if missing
	if _, err := run.Cmd(ctx, "", nil,
		"aws", "iam", "get-user", "--user-name", userName); err != nil {
		slog.Info("creating IAM user", "user", userName)
		if _, err := run.Cmd(ctx, "", nil,
			"aws", "iam", "create-user", "--user-name", userName); err != nil {
			return nil, fmt.Errorf("creating IAM user: %w", err)
		}
	} else {
		slog.Info("IAM user exists, will rotate key", "user", userName)
	}

	// Create or update policy
	if err := ensurePolicy(ctx, policyName, policyARN); err != nil {
		return nil, err
	}

	// Attach policy to user
	if _, err := run.Cmd(ctx, "", nil,
		"aws", "iam", "attach-user-policy",
		"--user-name", userName,
		"--policy-arn", policyARN); err != nil {
		return nil, fmt.Errorf("attaching policy: %w", err)
	}

	// Delete existing access keys (key rotation for re-runs)
	if err := deleteExistingKeys(ctx, userName); err != nil {
		return nil, err
	}

	// Create new access key
	slog.Info("creating access key", "user", userName)
	keyJSON, err := run.Cmd(ctx, "", nil,
		"aws", "iam", "create-access-key", "--user-name", userName)
	if err != nil {
		return nil, fmt.Errorf("creating access key: %w", err)
	}

	return []byte(keyJSON), nil
}

func ensurePolicy(ctx context.Context, policyName, policyARN string) error {
	// Write policy to temp file
	tmpFile, err := os.CreateTemp("", "policy-*.json")
	if err != nil {
		return fmt.Errorf("creating temp policy file: %w", err)
	}
	defer os.Remove(tmpFile.Name())

	if _, err := tmpFile.WriteString(builderPolicy); err != nil {
		tmpFile.Close()
		return fmt.Errorf("writing policy: %w", err)
	}
	tmpFile.Close()

	// Check if policy exists
	_, err = run.Cmd(ctx, "", nil,
		"aws", "iam", "get-policy", "--policy-arn", policyARN)
	if err != nil {
		// Create new policy
		slog.Info("creating policy", "name", policyName)
		_, err = run.Cmd(ctx, "", nil,
			"aws", "iam", "create-policy",
			"--policy-name", policyName,
			"--policy-document", fmt.Sprintf("file://%s", filepath.Clean(tmpFile.Name())))
		return err
	}

	// Policy exists — prune versions if at limit, then create new version
	slog.Info("updating policy", "name", policyName)
	versionsJSON, err := run.Cmd(ctx, "", nil,
		"aws", "iam", "list-policy-versions", "--policy-arn", policyARN)
	if err != nil {
		return fmt.Errorf("listing policy versions: %w", err)
	}

	oldest, count, err := parseOldestNonDefaultVersion([]byte(versionsJSON))
	if err != nil {
		return err
	}

	if count >= 5 && oldest != "" {
		slog.Info("pruning oldest policy version", "version", oldest)
		if _, err := run.Cmd(ctx, "", nil,
			"aws", "iam", "delete-policy-version",
			"--policy-arn", policyARN,
			"--version-id", oldest); err != nil {
			return fmt.Errorf("pruning policy version: %w", err)
		}
	}

	_, err = run.Cmd(ctx, "", nil,
		"aws", "iam", "create-policy-version",
		"--policy-arn", policyARN,
		"--policy-document", fmt.Sprintf("file://%s", filepath.Clean(tmpFile.Name())),
		"--set-as-default")
	return err
}

func deleteExistingKeys(ctx context.Context, userName string) error {
	keysJSON, err := run.Cmd(ctx, "", nil,
		"aws", "iam", "list-access-keys", "--user-name", userName)
	if err != nil {
		return fmt.Errorf("listing access keys: %w", err)
	}

	keys, err := parseAccessKeyIDs([]byte(keysJSON))
	if err != nil {
		return err
	}

	for _, keyID := range keys {
		slog.Info("deleting old access key", "key", keyID)
		if _, err := run.Cmd(ctx, "", nil,
			"aws", "iam", "delete-access-key",
			"--user-name", userName,
			"--access-key-id", keyID); err != nil {
			return fmt.Errorf("deleting access key %s: %w", keyID, err)
		}
	}

	return nil
}
