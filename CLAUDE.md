# CLAUDE.md — Project Instructions for Claude Code

## Project Overview

This is `aerospike/shared-workflows`, a centralized collection of reusable GitHub Actions workflows and composite actions used across Aerospike repositories. It is public because many consuming repos are public.

## Repository Structure

```text
.github/
├── actions/                      # Composite GitHub Actions
│   └── <action-name>/
│       ├── action.yaml
│       └── README.md
└── workflows/
    ├── reusable_<name>.yaml      # Reusable workflows (workflow_call entry points)
    ├── test_<name>.yaml          # CI test workflows
    ├── example_<name>.yaml       # Working usage examples
    └── <name>/                   # Supporting scripts, tests, README per workflow
        ├── entrypoint.sh
        ├── tests/
        └── README.md
```

**Key constraint**: GitHub Actions requires reusable workflows at `.github/workflows/` root — they cannot be nested in subdirectories. We use prefixes (`reusable_`, `test_`, `example_`) to simulate namespacing.

## Core Workflows

| Workflow                              | Purpose                                                           |
| ------------------------------------- | ----------------------------------------------------------------- |
| `reusable_artifacts-cicd.yaml`        | **Recommended entry point.** Orchestrates build -> sign -> deploy |
| `reusable_execute-build.yaml`         | Run arbitrary build script, upload artifacts                      |
| `reusable_sign-artifacts.yaml`        | GPG sign deb/rpm/generic, SSL.com sign nupkg                      |
| `reusable_deploy-artifacts.yaml`      | Upload to JFrog Artifactory (auto-routes by package type)         |
| `reusable_docker-build-deploy.yaml`   | Multi-arch OCI images with SLSA attestations                      |
| `reusable_create-release-bundle.yaml` | JFrog release bundles                                             |

## Naming Convention (v2.0.0+)

All workflow inputs use hyphens and namespace prefixes:

- `jf-*` — JFrog/Artifactory params (`jf-project`, `jf-build-name`, `jf-url`)
- `gh-*` — GitHub Actions params (`gh-artifact-name`, `gh-checkout-path`)
- `oidc-*` — Authentication params (`oidc-provider-name`, `oidc-audience`)
- No prefix for general params (`runs-on`, `dry-run`, `version`)

Required inputs listed first, then optional (alphabetical).

## gh-workflows-ref Workaround

All reusable workflows require a `gh-workflows-ref` input that **must match** the version in the caller's `uses:` line. This exists because GitHub Actions provides no `github.called_workflow_ref` — reusable workflows cannot discover their own ref. Without this, entrypoint scripts would be checked out from the wrong version.

See: `.github/workflows/docs/CICD-with-shared-actions.md#why-gh-workflows-ref-is-required`

## Running Tests

### Bats tests (shell script validation)

```bash
# Deploy-artifacts tests
bats .github/workflows/deploy-artifacts/tests/bats/

# Artifacts-CICD tests
bats .github/workflows/artifacts-cicd/tests/

# Individual test file
bats .github/workflows/deploy-artifacts/tests/bats/test_deb_rpm_upload.bats
```

### Entrypoint script tests

```bash
.github/workflows/execute-build/test-entrypoint.sh
.github/workflows/create-release-bundle/test-entrypoint.sh
```

### Linting

```bash
trunk check          # Run all linters
trunk fmt            # Auto-format
trunk git-hooks sync # Set up pre-commit hooks
```

## Coding Conventions

- **Entrypoint scripts**: 4-space indentation, consistent error handling (`handle_error()`/`error()`), `run()` for dry-run support, standard arg parsing with `--help`
- **Makefiles**: Tabs for recipe lines (never spaces)
- **YAML**: Avoid unnecessary quotes. Quotes required for JSON objects (`"{}"`), special chars, empty strings
- **Actions**: SHA-pin all dependencies with semver comment (e.g., `actions/checkout@abc123 # v4.2.0`)

## Versioning

Consumers should pin to commit SHAs with a semver comment. Dependabot keeps them updated:

```yaml
# Correct
uses: aerospike/shared-workflows/.github/workflows/reusable_artifacts-cicd.yaml@<sha> # v2.0.3

# Incorrect
uses: aerospike/shared-workflows/.github/workflows/reusable_artifacts-cicd.yaml@main
```

## Internal vs External Workflow References

- **Internal** (test/example workflows in this repo): Use relative paths with `gh-checkout-path: .`
  ```yaml
  uses: ./.github/workflows/reusable_execute-build.yaml
  ```
- **External** (consumer repos): Use tagged versions with matching `gh-workflows-ref`
