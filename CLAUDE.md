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

Consumers should use the **orchestrated workflows** (`reusable_artifacts-cicd.yaml`, `reusable_docker-build-deploy.yaml`) as their entry points. These are opinionated pipelines with good defaults that handle the full lifecycle (build -> sign -> deploy). They trade flexibility for simplicity and correctness.

The lower-level composable workflows (`reusable_execute-build.yaml`, `reusable_sign-artifacts.yaml`, `reusable_deploy-artifacts.yaml`) exist primarily as implementation details of the orchestrators. Direct use of these should be rare — if a consumer needs to call them directly, that's a smell indicating either the orchestrator is missing a needed capability or the consumer's build process needs to be restructured. Avoid adding escape hatches to the orchestrators unless there is a clear production need; instead, prefer making the standard path work.

| Workflow                              | Purpose                                                          |
| ------------------------------------- | ---------------------------------------------------------------- |
| `reusable_artifacts-cicd.yaml`        | **Primary entry point.** Orchestrates build -> sign -> deploy    |
| `reusable_docker-build-deploy.yaml`   | **Primary entry point.** Multi-arch OCI images with attestations |
| `reusable_create-release-bundle.yaml` | JFrog release bundles (combines artifact + docker outputs)       |
| `reusable_execute-build.yaml`         | _Internal._ Run arbitrary build script, upload artifacts         |
| `reusable_sign-artifacts.yaml`        | _Internal._ GPG sign deb/rpm/generic, SSL.com sign nupkg         |
| `reusable_deploy-artifacts.yaml`      | _Internal._ Upload to JFrog Artifactory (auto-routes by type)    |

## Naming Convention (v2.0.0+)

All workflow inputs use hyphens and namespace prefixes:

- `jf-*` — JFrog/Artifactory params (`jf-project`, `jf-build-name`, `jf-url`)
- `gh-*` — GitHub Actions params (`gh-artifact-name`, `gh-checkout-path`)
- `oidc-*` — Authentication params (`oidc-provider-name`, `oidc-audience`)
- No prefix for general params (`runs-on`, `dry-run`, `version`)

Required inputs listed first, then optional (alphabetical).

## gh-workflows-ref Workaround

All reusable workflows require a `gh-workflows-ref` input that **must match** the version in the caller's `uses:` line. This exists because GitHub Actions provides no `github.called_workflow_ref` — reusable workflows cannot discover their own ref. Without this, entrypoint scripts would be checked out from the wrong version.

See: `.github/workflows/docs/why-gh-workflows-ref.md`

## Artifact Pipeline Detail

The `reusable_artifacts-cicd.yaml` orchestrator runs 5 jobs. Understanding the artifact transforms at each stage is critical for debugging.

### Jobs: resolve -> build -> collect-matrix-artifacts -> sign -> deploy-signed

### Build stage (`reusable_execute-build.yaml`)

- Each matrix variant uploads its own GH artifact: `build-artifacts-{distro}-{arch}`
- Upload path: `{working-directory}/{gh-artifact-directory}` — contents are flattened (upload-artifact strips the path prefix)
- Build scripts run as temp subprocess files — `build-env` vars (including `MATRIX_JSON`) are exported, but vars set inside the script with plain `VAR=val` are local. **Must `export` them** for child processes (make, docker) to see them.

### Collect stage (`collect-matrix-artifacts` job)

- `download-artifact` with `pattern: build-artifacts-*` and `merge-multiple: true`
- All files from all matrix artifacts merge flat into `build-artifacts/`
- **Collision risk**: if two matrix builds produce files with the same name, one silently overwrites the other
- Re-uploads as single `build-artifacts` artifact

### Sign stage (`reusable_sign-artifacts.yaml`)

- Downloads `build-artifacts` into `unsigned-artifacts/`
- **NuGet separation**: `.nupkg` files are **moved** out to `unsigned-nuget-packages/` before GPG signing, signed separately via SSL.com eSigner -> output to `signed-artifacts/nuget/`
- **GPG signing**: entrypoint copies `unsigned-artifacts/**/*` with `cp --parents` to `signed-artifacts/` (preserves `unsigned-artifacts/` prefix), then signs deb (`dpkg-sig`), rpm (`rpm --addsign`), and creates `.asc` for all files
- Result structure: `signed-artifacts/unsigned-artifacts/{files}` + `signed-artifacts/nuget/{nupkg}`

### Deploy stage (`reusable_deploy-artifacts.yaml`)

- Downloads `signed-artifacts` into `./build-artifacts`
- `structure_build_artifacts()` uses recursive `find build-artifacts -name "*.{ext}"` to discover files
- Routes by extension: deb/rpm/jar/nupkg/snupkg each to their JFrog repo, everything else to generic
- Build-info aggregation: discovers child build-infos via AQL (`{metadata-build-id}*.json`), appends to parent build

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

- **Entrypoint scripts**: consistent error handling (`handle_error()`/`error()`), `run()` for dry-run support, standard arg parsing with `--help`
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
