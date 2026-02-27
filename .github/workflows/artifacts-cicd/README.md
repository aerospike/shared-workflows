# Artifacts CI/CD (Reusable Workflow)

This workflow orchestrates the standard artifacts pipeline:
build → sign → deploy. It wraps the lower-level reusable workflows and
provides a small, opinionated input surface.

## Design Philosophy

The CI reusable workflows in this repo follow two tiers:

- **Composable workflows** (`reusable_execute-build.yaml`, `reusable_sign-artifacts.yaml`, `reusable_deploy-artifacts.yaml`) — flexible building blocks with good defaults and escape hatches. Callers can mix and match these to build custom pipelines.

- **Orchestrator** (`reusable_artifacts-cicd.yaml`) — an opinionated wrapper that ties the composable workflows together into a standard build → sign → deploy pipeline. It intentionally limits flexibility in favor of simplicity. In most cases, the end state is artifacts uploaded to JFrog.

Use the orchestrator when the standard pipeline fits your needs. Use the composable workflows directly when you need more control.

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
