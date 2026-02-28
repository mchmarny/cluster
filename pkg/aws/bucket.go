package aws

import (
	"context"
	"fmt"
	"log/slog"

	"github.com/mchmarny/cluster/pkg/run"
)

// EnsureBucket creates (if needed) and configures an S3 bucket for Terraform state.
func EnsureBucket(ctx context.Context, bucket, region string) error {
	slog.Info("ensuring state bucket", "bucket", bucket, "region", region)

	// Check if bucket exists
	_, err := run.Cmd(ctx, "", nil,
		"aws", "s3api", "head-bucket", "--bucket", bucket, "--region", region)
	if err != nil {
		slog.Info("creating bucket", "bucket", bucket)
		if err := createBucket(ctx, bucket, region); err != nil {
			return err
		}
	} else {
		slog.Info("bucket already exists", "bucket", bucket)
	}

	// Enable versioning
	if _, err := run.Cmd(ctx, "", nil,
		"aws", "s3api", "put-bucket-versioning",
		"--bucket", bucket, "--region", region,
		"--versioning-configuration", "Status=Enabled"); err != nil {
		return fmt.Errorf("enabling versioning: %w", err)
	}

	// Block public access
	if _, err := run.Cmd(ctx, "", nil,
		"aws", "s3api", "put-public-access-block",
		"--bucket", bucket, "--region", region,
		"--public-access-block-configuration",
		"BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"); err != nil {
		return fmt.Errorf("blocking public access: %w", err)
	}

	// Enable SSE-KMS encryption
	if _, err := run.Cmd(ctx, "", nil,
		"aws", "s3api", "put-bucket-encryption",
		"--bucket", bucket, "--region", region,
		"--server-side-encryption-configuration",
		`{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms"}}]}`); err != nil {
		return fmt.Errorf("enabling encryption: %w", err)
	}

	slog.Info("bucket configured", "bucket", bucket)
	return nil
}

func createBucket(ctx context.Context, bucket, region string) error {
	// us-east-1 doesn't accept LocationConstraint
	if region == "us-east-1" {
		_, err := run.Cmd(ctx, "", nil,
			"aws", "s3api", "create-bucket",
			"--bucket", bucket, "--region", region)
		return err
	}

	_, err := run.Cmd(ctx, "", nil,
		"aws", "s3api", "create-bucket",
		"--bucket", bucket, "--region", region,
		"--create-bucket-configuration", fmt.Sprintf("LocationConstraint=%s", region))
	return err
}
