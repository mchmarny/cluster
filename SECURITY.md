# Security

**Please do not report security vulnerabilities through public GitHub issues, pull requests or discussions.**

## Reporting Security Vulnerabilities

Report a potential vulnerability privately through GitHub:
[open a private security advisory](https://github.com/mchmarny/cluster/security/advisories/new)
(**Security** tab → **Report a vulnerability**). Only the maintainer can see the report.

Include in your report:

- The affected image and version (for example `ghcr.io/mchmarny/cluster/eks:v0.5.4`), or the commit SHA
- The provider (EKS, GKE, AKS or OKE) and the affected component (CLI, Terraform module, container image, workflow)
- The type of issue and its potential impact
- Steps to reproduce, and proof-of-concept code if you have it

## Acknowledgement and Response

This is a single-maintainer project, and reports are handled on a best-effort basis.
The maintainer acknowledges the report in the advisory, keeps the conversation there
while a fix is prepared, and credits the reporter in the published advisory unless
you ask otherwise. Please keep the issue confidential until the advisory is published.

## Out of Scope

The following generally do **not** qualify as vulnerabilities in this project:

- Vulnerabilities in upstream tools that the images bundle (Terraform, Terraform
  providers, `kubectl`, the AWS, Google Cloud, Azure and OCI CLIs). Report those to
  the owning project. Do report it here when this project's pinned version or
  default configuration is what exposes you.
- Findings that require already-compromised cloud credentials, a compromised
  operator workstation, or access to the Terraform state backend.
- Account, network or cluster hardening that is the operator's responsibility and
  is set through configuration (for example authorized networks or IAM scope).
- Theoretical weaknesses with no demonstrated, practical exploit path.

When in doubt, report it.

## Supported Versions

Each provider image is versioned and released independently (`v*-eks`, `v*-gke`,
`v*-aks`, `v*-oke`). Only the latest release of each provider image receives
security fixes. Fixes land on `main` and ship in a new patch release; they are not
backported to older tags. See [RELEASE.md](RELEASE.md).

## Supply Chain Security

Release images are built in GitHub Actions from a tag on `main`, on native amd64
and arm64 runners (no QEMU), with Terraform providers mirrored into the image at
build time. Every release:

- **Vulnerability gate**: the multi-arch image is scanned with
  [Grype](https://github.com/anchore/grype) (version pinned in
  [`.settings.yaml`](.settings.yaml)) using `--only-fixed --fail-on critical`.
  Results are uploaded to the repository's code scanning alerts.
- **VEX triage**: [`.openvex.json`](.openvex.json) (OpenVEX v0.2.0) records, per CVE
  and per image (`pkg:oci/<provider>`), why a finding does not affect the image,
  with the evidence and the condition for re-checking or removing the statement.
  It is applied at scan time.
- **Build provenance**: a SLSA v1 provenance attestation, signed with Sigstore
  through GitHub Actions OIDC by the release workflow and pushed to the registry
  with the image.

### Verify an Image

Resolve the release tag to its immutable digest, then verify the provenance. The
image tag drops the provider suffix of the release tag (`v0.5.4-eks` publishes
`eks:v0.5.4`). Requires Docker with `buildx`, `jq`, and an authenticated
[GitHub CLI](https://cli.github.com/) (`gh auth login`).

```shell
TAG=v0.5.4-eks
IMAGE=ghcr.io/mchmarny/cluster/eks
DIGEST=$(docker buildx imagetools inspect "${IMAGE}:${TAG%-*}" --format '{{json .Manifest}}' | jq -r .digest)

gh attestation verify "oci://${IMAGE}@${DIGEST}" \
  --repo mchmarny/cluster \
  --signer-workflow mchmarny/cluster/.github/workflows/on-tag.yaml \
  --source-ref "refs/tags/${TAG}"
```

Deploy by digest (`${IMAGE}@${DIGEST}`) rather than by tag so that what you run is
what you verified.
