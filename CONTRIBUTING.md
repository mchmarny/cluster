# Contributing

Contributions are welcome, from bug reports to new provider features.

## Code of Conduct

This project adopts the Contributor Covenant v2.1. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Getting Started

1. Read the [README](README.md) and the guide for the provider you are changing
   ([EKS](provider/eks/README.md), [GKE](provider/gke/README.md),
   [AKS](provider/aks/README.md), [OKE](provider/oke/README.md)).
2. Search [existing issues](https://github.com/mchmarny/cluster/issues) to avoid duplicates.
3. Report security issues privately; see [SECURITY.md](SECURITY.md).
4. Coding assistants: the project rules in [`.claude/CLAUDE.md`](.claude/CLAUDE.md) apply.

## How to Contribute

- **Bugs**: use the [bug report form](https://github.com/mchmarny/cluster/issues/new?template=bug_report.yml).
- **Enhancements**: use the [feature request form](https://github.com/mchmarny/cluster/issues/new?template=feature_request.yml).
- **Code and docs**: open an issue first for anything beyond a small fix, so the
  approach can be agreed before you invest in it. Reference it from the PR with
  `Fixes #N`.

## Development

Tool versions are pinned in [`.settings.yaml`](.settings.yaml), the single source of
truth for local builds and CI. Change versions there only; the `Makefile`, CI and
Dockerfiles read from it.

```bash
make tools-check  # Compare installed tools with .settings.yaml
make qualify      # All checks CI runs: Go vet/fmt/lint/test/build, Terraform validate/test/lint/fmt, Trivy
make go-test      # Go unit tests with the race detector
make tf-test      # terraform test in each provider/<csp>/terraform
make build-eks    # Build a provider image locally (needs Docker); also build-gke, build-aks, build-oke
```

## Project Conventions

- **Configuration-driven.** Every infrastructure value flows from the YAML config
  through `yamldecode()` into `locals {}` (with `try()` defaults for optional
  fields) and then into resources. Do not hardcode values a user may need to change.
- **Private by default.** Private API endpoints, authorized networks, and workload
  identity rather than static credentials in pods.
- **Node pool separation.** Cluster components run on the system pool; user
  workloads run on worker pools.
- **Account validation.** EKS, GKE and AKS fail the plan when the active account,
  project or subscription differs from `deployment.tenancy` (a lifecycle
  `precondition` on the base network resource), and OKE resolves the configured
  tenancy before using it. Keep these guards; they prevent cross-account mistakes.
- **Provider helpers live in their package.** For example, AWS naming helpers are
  in `pkg/aws`, not on the generic `Config`.

When you change a provider:

- Follow the module layout in `provider/<csp>/terraform` (`variables.tf` takes
  only `CONFIG_PATH`; `main.tf` holds the locals; `cluster.tf`, `compute.tf`,
  `network.tf`, `iam.tf`, `outputs.tf`).
- Add or update plan-time tests in `provider/<csp>/terraform/tests` (EKS, GKE and
  OKE have them; AKS does not yet, and `make tf-test` skips providers without one).
- Update the JSON schema in [`schema/`](schema/), the provider README, and the
  example configs in [`config/`](config/) when the configuration changes.

## Pull Request Process

### Before Submitting

1. Run `make qualify`; CI requires the same checks (`qualify / Go Lint`,
   `qualify / Go Test`, `qualify / Terraform Check`).
2. Update the documentation for any user-facing change.
3. **Sign every commit** (`git commit -S`). `main` requires verified signatures; see
   [signing commits](https://docs.github.com/en/authentication/managing-commit-signature-verification/signing-commits).
   No DCO sign-off is required.

### Creating the Pull Request

- Open the PR against `main` and fill out the template, including the
  `release-note` block. Write `NONE` if no note is needed, and include the string
  `action required` if users must change anything to upgrade.
- PRs are squash-merged, and the PR title becomes the whole commit on `main`
  (the commit body is left empty). Use a
  [Conventional Commits](https://www.conventionalcommits.org/) title, scoped to the
  provider where it applies: `fix(eks): ...`, `feat(oke): ...`, `docs: ...`,
  `chore: ...`.
- Workflows on PRs from forks run after a maintainer approves them, so CI may
  stay pending at first.

### Review

- One approving review is required, and review threads must be resolved.
- The branch must be up to date with `main` before it can merge, and a push after
  approval dismisses the approval, so the latest push always needs a review.
- Address feedback with new commits rather than force-pushes, so review comments
  keep their anchors. The squash merge collapses the history anyway.
- A maintainer merges once CI passes and the review is approved.

### AI-Assisted Contributions

AI tools are welcome, with a human in the loop:

- **Full accountability.** By opening a PR you accept responsibility for its
  correctness, security, maintainability and license compliance.
- **Understand what you submit.** Be ready to explain and defend every line.

## Getting Help

See [SUPPORT.md](SUPPORT.md).

## Additional Resources

- [README.md](README.md): overview, CLI and configuration
- [RELEASE.md](RELEASE.md): how releases are cut and published
- [SECURITY.md](SECURITY.md): reporting vulnerabilities and verifying images
