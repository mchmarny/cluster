package aws

import (
	"testing"
)

func TestParsePolicyVersions(t *testing.T) {
	jsonResp := `{
		"Versions": [
			{"VersionId": "v1", "IsDefaultVersion": false, "CreateDate": "2024-01-01T00:00:00Z"},
			{"VersionId": "v2", "IsDefaultVersion": true, "CreateDate": "2024-01-02T00:00:00Z"},
			{"VersionId": "v3", "IsDefaultVersion": false, "CreateDate": "2024-01-03T00:00:00Z"}
		]
	}`

	oldest, count, err := parseOldestNonDefaultVersion([]byte(jsonResp))
	if err != nil {
		t.Fatalf("parseOldestNonDefaultVersion() error: %v", err)
	}
	if count != 3 {
		t.Errorf("count = %d, want 3", count)
	}
	if oldest != "v1" {
		t.Errorf("oldest = %q, want %q", oldest, "v1")
	}
}

func TestParsePolicyVersionsAllDefault(t *testing.T) {
	jsonResp := `{
		"Versions": [
			{"VersionId": "v1", "IsDefaultVersion": true, "CreateDate": "2024-01-01T00:00:00Z"}
		]
	}`

	oldest, count, err := parseOldestNonDefaultVersion([]byte(jsonResp))
	if err != nil {
		t.Fatalf("error: %v", err)
	}
	if count != 1 {
		t.Errorf("count = %d, want 1", count)
	}
	if oldest != "" {
		t.Errorf("oldest = %q, want empty", oldest)
	}
}

func TestParseAccessKeys(t *testing.T) {
	jsonResp := `{
		"AccessKeyMetadata": [
			{"AccessKeyId": "AKIA1", "Status": "Active"},
			{"AccessKeyId": "AKIA2", "Status": "Inactive"}
		]
	}`

	keys, err := parseAccessKeyIDs([]byte(jsonResp))
	if err != nil {
		t.Fatalf("error: %v", err)
	}
	if len(keys) != 2 {
		t.Fatalf("len = %d, want 2", len(keys))
	}
	if keys[0] != "AKIA1" || keys[1] != "AKIA2" {
		t.Errorf("keys = %v, want [AKIA1 AKIA2]", keys)
	}
}

func TestParseCallerIdentity(t *testing.T) {
	jsonResp := `{"Account": "123456789012"}`

	account, err := parseAccountID([]byte(jsonResp))
	if err != nil {
		t.Fatalf("error: %v", err)
	}
	if account != "123456789012" {
		t.Errorf("account = %q, want %q", account, "123456789012")
	}
}
