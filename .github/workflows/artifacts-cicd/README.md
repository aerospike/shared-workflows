# Artifacts CI/CD (Reusable Workflow)

This workflow orchestrates the standard artifacts pipeline:
build → sign → deploy. It wraps the lower-level reusable workflows and
provides a small, opinionated input surface.

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

Comprehensive integration tests are located in `tests/` and run via `.github/workflows/test_artifacts-cicd-workflow.yaml`.

### Test Coverage

1. **Multi-Distro Matrix** (`test_multi_distro_collection.bats`)
   - Validates artifact collection from multiple matrix builds (el9, jammy, noble)
   - Ensures no artifacts are lost during merge
   - Checks for correct artifact counts per distro

2. **Mixed Artifact Types** (`test_mixed_artifacts.bats`)
   - Tests native (deb/rpm) + dotnet (nupkg) builds in same workflow
   - Validates different artifact types coexist properly
   - Checks naming conventions and type-specific handling

3. **Signing Verification** (`test_artifact_signing.bats`)
   - Ensures all artifacts have corresponding signature files (.asc)
   - Validates signature file format and presence

### Running Tests

```bash
# Run all tests
act workflow_dispatch -W .github/workflows/test_artifacts-cicd-workflow.yaml

# Run specific verification job
act workflow_dispatch -j verify-multi-distro
```

Tests run automatically in PR checks when artifacts-cicd related files change.
