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

Two approaches are supported as first-class consumer paths:

- **Orchestrated** (`reusable_artifacts-cicd.yaml`, `reusable_docker-build-deploy.yaml`): opinionated pipelines with good defaults that handle the full lifecycle (build, sign, deploy). Smaller input surface, less wiring, less flexibility.
- **Composable** (`reusable_execute-build.yaml`, `reusable_sign-artifacts.yaml`, `reusable_deploy-artifacts.yaml`): call the per-stage workflows directly from your own job graph when you need custom steps between stages, per-stage overrides, or non-standard layouts. More wiring, more flexibility.

Pick whichever fits the use case. The orchestrated path is generally lower-maintenance for new consumers; the composable path is the right answer when the orchestrator's opinions don't match. Both are supported, neither is a fallback.

| Workflow                              | Purpose                                                         |
| ------------------------------------- | --------------------------------------------------------------- |
| `reusable_artifacts-cicd.yaml`        | Orchestrated build, sign, deploy                                |
| `reusable_docker-build-deploy.yaml`   | Multi-arch OCI images with attestations                         |
| `reusable_create-release-bundle.yaml` | JFrog release bundles (combines artifact + docker outputs)      |
| `reusable_execute-build.yaml`         | Composable. Run arbitrary build script, upload artifacts        |
| `reusable_sign-artifacts.yaml`        | Composable. GPG sign deb/rpm/generic/.tgz, SSL.com sign nupkg   |
| `reusable_deploy-artifacts.yaml`      | Composable. Upload to JFrog Artifactory (auto-routes by type)   |
| `reusable_notify-slack.yaml`          | Post Block Kit Slack alerts (info/fail/success/blocked/warning) |

### Slack notification actions

| Action / workflow       | Purpose                                                       |
| ----------------------- | ------------------------------------------------------------- |
| `notify-slack`          | Build container-style Block Kit alert; calls `send-slack`     |
| `send-slack`            | Low-level `chat.postMessage` transport (`slack_post.py`)      |
| `reusable_notify-slack` | Reusable workflow wrapper (sparse checkout + notify pipeline) |

Two consumer paths (same as artifact pipelines — pick what fits):

- **Reusable workflow** (`reusable_notify-slack.yaml`): lowest wiring for callers; no Slack secret passed from consumer repos.
- **Composable actions** (`notify-slack` → `send-slack`): use when you need custom steps between build and send, or a non-standard job layout.

Architecture: `notify-slack` → `prep_blockkit.py` + `templates/container.json` → `send-slack` → Slack API.

Message types: `info`, `fail`, `success`, `blocked`, `warning`. Per-type icon/collapsible styling is configured in `MESSAGE_TYPE_CONFIG` inside `prep_blockkit.py`; callers supply detail via the `child-blocks` JSON input.

Authentication: `SLACK_BOT_TOKEN` is a **shared-workflows repo secret**, injected via job `env:` — not an action input. Consumers still pass `slack-channel-id` (typically from their own repo `vars`/`secrets`). Dry-run does not require a token.

Docs: `.github/actions/notify-slack/README.md`, `.github/actions/send-slack/README.md`, `.github/workflows/docs/notify-slack.md`. Examples: `example_notify-slack.yaml`, tests: `test_notify-slack.yaml`, live integration: `test_notify-slack-integration.yaml` (optional).

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
- Build scripts run as temp subprocess files. `build-env` vars are parsed (semicolon-delimited `KEY=VALUE`) and exported; `MATRIX_JSON` is carried via a dedicated `matrix-json-data` input and also exported. Vars set inside the build script with plain `VAR=val` are local. **Must `export` them** for child processes (make, docker) to see them.

### Collect stage (`collect-matrix-artifacts` job)

- `download-artifact` with `pattern: build-artifacts-*` and **`merge-multiple: false`** so each matrix artifact extracts under its own subdirectory (avoids parallel unpack races into the same basename, which can corrupt zips such as wheels)
- `merge_flat.sh` copies every file **sequentially** into a flat `build-artifacts/` tree (`cp -p`)
- **Duplicate basename** across matrix artifacts is a hard error (exit 1 with paths) instead of silent overwrite; fix matrix outputs or artifact layout if this triggers
- Re-uploads as single `build-artifacts` artifact

### Sign stage (`reusable_sign-artifacts.yaml`)

- Downloads `build-artifacts` into `unsigned-artifacts/`
- **NuGet separation**: `.nupkg` files are **moved** out to `unsigned-nuget-packages/` before GPG signing, signed separately via SSL.com eSigner -> output to `signed-artifacts/nuget/`
- **GPG signing**: entrypoint copies `unsigned-artifacts/**/*` with `cp --parents` to `signed-artifacts/` (preserves `unsigned-artifacts/` prefix), then signs deb (`dpkg-sig`), rpm (`rpm --addsign`), and creates `.asc` for all files
- Result structure: `signed-artifacts/unsigned-artifacts/{files}` + `signed-artifacts/nuget/{nupkg}`

### Deploy stage (`reusable_deploy-artifacts.yaml`)

- Downloads `signed-artifacts` into `./build-artifacts`
- `structure_build_artifacts()` uses recursive `find build-artifacts -name "*.{ext}"` to discover files
- Routes by extension: deb/rpm/jar/nupkg/snupkg each to their JFrog repo. Ambiguous archives (`.tgz`, `.tar.gz`, `.zip`) are content-detected (npm, pypi, go, helm) via `is_*` predicates in `type_detection.sh`. Anything that doesn't match falls back to generic.
- Build-info aggregation: discovers child build-infos via AQL (`{metadata-build-id}*.json`), appends to parent build
- After deploy, `detect_types.sh` may write `structured_build_artifacts/.maven-bundle-metadata.json`; the workflow can upload it as a GitHub artifact (outputs `bundle-metadata-artifact-name` / `bundle-metadata-available`) for `reusable_create-release-bundle.yaml` via `gh-bundle-metadata-artifact-name`.

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

### Slack notify tests

```bash
python3 -m unittest discover .github/actions/send-slack/tests
python3 -m unittest discover .github/actions/notify-slack/tests
bats .github/actions/send-slack/tests/test_slack_post.bats
bats .github/actions/notify-slack/tests/test_prep_blockkit.bats
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
