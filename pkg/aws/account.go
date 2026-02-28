package aws

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"

	"github.com/mchmarny/cluster/pkg/run"
)

type callerIdentity struct {
	Account string `json:"Account"`
}

func parseAccountID(data []byte) (string, error) {
	var id callerIdentity
	if err := json.Unmarshal(data, &id); err != nil {
		return "", fmt.Errorf("parsing caller identity: %w", err)
	}
	return id.Account, nil
}

// ValidateAccount verifies the active AWS account matches the expected tenancy.
func ValidateAccount(ctx context.Context, expectedAccount string) error {
	out, err := run.Cmd(ctx, "", nil,
		"aws", "sts", "get-caller-identity", "--output", "json")
	if err != nil {
		return fmt.Errorf("getting caller identity: %w", err)
	}

	account, err := parseAccountID([]byte(out))
	if err != nil {
		return err
	}

	if account != expectedAccount {
		return fmt.Errorf("AWS account mismatch (want: %s, got: %s)", expectedAccount, account)
	}

	slog.Info("account validated", "account", account)
	return nil
}
