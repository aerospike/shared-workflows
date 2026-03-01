# Artifacts CI/CD (Reusable Workflow)

This workflow orchestrates the standard artifacts pipeline:
build → sign → deploy. It wraps the lower-level reusable workflows and
provides a small, opinionated input surface.

## Design Philosophy

This orchestrator is the expected entry point for all artifact CI/CD. It handles the full build → sign → deploy lifecycle with good defaults and minimal configuration.

The lower-level workflows it wraps (`reusable_execute-build.yaml`, `reusable_sign-artifacts.yaml`, `reusable_deploy-artifacts.yaml`) are internal implementation details. If a consumer needs to call them directly, that's a smell — either this orchestrator is missing a needed capability, or the consumer's build process should be restructured to fit the standard path. Prefer extending the orchestrator over bypassing it.

## Usage

```yaml
jobs:
  ci:
    uses: aerospike/shared-workflows/.github/workflows/reusable_artifacts-cicd.yaml@v2.0.3
    with:
      gh-workflows-ref: v2.0.3
      jf-project: my-project
      jf-build-name: my-app
      version: 1.2.3
      gh-artifact-directory: dist
      build-script: |
        make build
    secrets: inherit
```

## Notes

- The workflow generates a parent build-id automatically.

## Testing

Integration tests are split into three independent workflow files, each calling the orchestrator once and verifying the results with bats:

| Workflow                                 | Bats test                           | What it validates                                      |
| ---------------------------------------- | ----------------------------------- | ------------------------------------------------------ |
| `test_artifacts-cicd-multi-distro.yaml`  | `test_multi_distro_collection.bats` | Artifact collection from el9/jammy/noble matrix builds |
| `test_artifacts-cicd-mixed-matrix.yaml`  | `test_mixed_artifacts.bats`         | Native (deb/rpm) + dotnet (nupkg) coexistence          |
| `test_artifacts-cicd-full-workflow.yaml` | `test_artifact_signing.bats`        | End-to-end build + sign, signature file verification   |

Tests are split into separate workflows so each gets its own artifact namespace (avoiding name collisions from the orchestrator's hardcoded artifact names).

### Running Tests

```bash
# Run bats tests locally (unit-level, no workflow execution)
bats .github/workflows/artifacts-cicd/tests/
```

Tests run automatically as PR checks.
