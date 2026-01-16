# Build Action Example

This is a minimal composite action that demonstrates the required contract for `build-action` in `reusable_artifacts-cicd.yaml`.

## Contract

- Must emit `artifact-directory` and `artifact-name` outputs.
- Must produce artifacts in the directory named by `artifact-directory`.
- May consume `BUILD_ACTION_INPUTS` from the environment for custom input parsing.

## Inputs

- `artifact-directory` (default: `dist`)
- `artifact-name` (default: `build-artifacts-example`)
- `build-script` (optional inline script)

## Example usage

```yaml
jobs:
  ci:
    uses: aerospike/shared-workflows/.github/workflows/reusable_artifacts-cicd.yaml@v2.0.3
    with:
      gh-workflows-ref: v2.0.3
      jf-project: my-project
      jf-build-name: my-app
      version: 1.2.3
      build-action: aerospike/shared-workflows/.github/actions/build-action-example@v2.0.3
      build-action-inputs: >-
        {"target":"release"}
```
