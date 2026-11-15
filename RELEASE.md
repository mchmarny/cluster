# Release Process

This document describes when and how releases are made. For contribution guidelines, see [CONTRIBUTING.md](CONTRIBUTING.md).

## Model

Each provider image is released independently. A release is a tag on `main` named
`vX.Y.Z-<provider>`, where `<provider>` is `eks`, `gke`, `aks` or `oke`. Pushing it
publishes:

| Tag | Image |
|-----|-------|
| `v0.5.4-eks` | `ghcr.io/mchmarny/cluster/eks:v0.5.4` and `:latest` |

Releases are tags and images only; no GitHub Release objects are created. A
release ships everything merged to `main` since that provider's last tag. There
are no release branches and no cherry-picks.

## Versioning

Versions are SemVer-style `vX.Y.Z`, per provider, with these project rules:

| Bump | When |
|------|------|
| `patch` | Bug fixes, security fixes, tool bumps and backward-compatible features |
| `minor` | The release needs user action, for example a new default that would replace existing resources unless the configuration is updated |
| `major` | Reserved for incompatible changes to the configuration schema or CLI |

A PR whose change needs user action says so in its `release-note` block with the
string `action required`.

## Quality Gates

Every release must pass these gates, which run on the tag:

- The `make qualify` checks: Go vet, format, test (race detector), build and
  lint; Terraform validate, test, lint and format; a Trivy configuration scan
- An image vulnerability scan with Grype, failing on fixed critical CVEs not
  covered by [`.openvex.json`](.openvex.json)
- A SLSA build provenance attestation for the published digest

## How to Release

### 1. Prepare `main`

```bash
git checkout main
git pull --ff-only origin main
git status            # must be clean
make qualify
```

The bump target tags local `HEAD`, so local `main` must match `origin/main`.

### 2. Pre-check the image scan

The release workflow pushes `:<version>` and `:latest` **before** the scan runs, so
a scan failure leaves those tags published without an attestation. Run the scan
locally first, especially when the provider's last release is more than a couple
of weeks old, because new upstream CVEs land in the bundled tools (Terraform,
`kubectl`, the cloud CLIs and their bundled Python).

```bash
make build-eks        # mirrors providers, builds cluster-eks:<version>

# VEX products are pkg:oci/<provider>; tag the local image under the release name
docker tag cluster-eks:latest ghcr.io/mchmarny/cluster/eks:precheck

# Use the Grype version pinned in .settings.yaml, not a newer local one:
# matching differs between versions.
grype docker:ghcr.io/mchmarny/cluster/eks:precheck \
  --config .grype.yaml --vex .openvex.json --only-fixed --fail-on critical
```

The local build covers only your host's architecture, while CI scans both, so a
clean pre-check makes a CI failure unlikely but does not rule it out.

If the scan fails, fix it on `main` before tagging (see
[Handling a Scan Failure](#handling-a-scan-failure)).

### 3. Tag

```bash
make bump-patch-eks   # v0.5.3-eks → v0.5.4-eks
# or bump-minor-<provider> / bump-major-<provider>
```

`make bump-<type>-<provider>` (wrapping [`tools/bump`](tools/bump)) checks for a
clean, pushed tree, computes the next version from the provider's latest tag,
refuses an existing tag, then creates and pushes an annotated tag. Do not create
or push release tags by hand.

### 4. Watch the pipeline

The run appears a few seconds after the tag push:

```bash
gh run list --workflow on-tag.yaml --branch v0.5.4-eks --limit 1   # note the run ID
gh run watch <run-id> --exit-status
```

Then [verify the published image](SECURITY.md#verify-an-image).

## Release Pipeline

[`.github/workflows/on-tag.yaml`](.github/workflows/on-tag.yaml):

```
Tag push --> Qualify --> Build (amd64, arm64) --> Manifest (:<version>, :latest) --> Grype scan --> Attest --> Summary
```

- **Build** runs on native amd64 and arm64 runners and pushes
  `:<version>-<arch>`, with the tool versions from
  [`.settings.yaml`](.settings.yaml) passed as build arguments.
- **Manifest** creates the multi-arch `:<version>` and `:latest`.
- **Scan** uploads SARIF to code scanning and fails the run on a critical
  finding.
- **Attest** pushes SLSA provenance for the manifest digest.

## Handling a Scan Failure

1. Prefer a fix: bump the affected tool in [`.settings.yaml`](.settings.yaml) (and
   the matching `Makefile` fallback and Dockerfile `ARG` default).
2. When no fixed version exists, add an OpenVEX statement to
   [`.openvex.json`](.openvex.json), scoped to the affected `pkg:oci/<provider>`.
   Its `impact_statement` carries reproducible evidence (what in the image is or
   is not reachable, and how it was checked) and names the condition for
   re-checking and for removing the statement. If the scanner reports the
   finding under an alias (for example a CVE ID for a Go advisory), list it in
   `aliases`. Bump the document `version` and `last_updated`.
3. Re-run the pre-check scan, merge the fix, and cut the next patch release.

If a tag already published unattested images, do not move or re-push the tag;
cut the next patch release so `:latest` moves to an attested image.

Remove a VEX statement once its removal condition is met, for example once the
bundled runtime ships the fixed version.

## Troubleshooting

| Problem | Action |
|---------|--------|
| `make bump-*` reports a dirty tree or unpushed commits | Commit and push, or reset local `main` to `origin/main` |
| `make bump-*` computes an unexpected version | Run `git fetch origin --tags`; it counts from the latest local `v*-<provider>` tag |
| `make build-<provider>` fails in `tools/mirror` | Terraform provider resolution failed; check registry access and your Terraform CLI configuration |
| The scan fails on the tag | See [Handling a Scan Failure](#handling-a-scan-failure) |
| A build or push step fails | Re-run the failed jobs of the same run; a new tag is needed only if `main` changes |

## Prerequisites

- Write access to the repository and permission to push tags
- Docker and the Grype version pinned in [`.settings.yaml`](.settings.yaml) for the pre-check
