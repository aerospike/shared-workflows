# Collect Build Artifacts

Download per-matrix build artifacts and merge them into a single artifact for downstream jobs (sign, deploy). This is the standard collect step in the composable pipeline pattern.

## Inputs

| Input            | Required | Default             | Description                                  |
| ---------------- | -------- | ------------------- | -------------------------------------------- |
| `pattern`        | No       | `build-artifacts-*` | Glob pattern to match artifact names         |
| `output-name`    | No       | `build-artifacts`   | Name for the merged output artifact          |
| `retention-days` | No       | `1`                 | Number of days to retain the merged artifact |

## Example Usage

```yaml
collect:
  needs: [build]
  runs-on: ubuntu-22.04
  steps:
    - uses: actions/checkout@v4
      with:
        sparse-checkout: .github/actions
        sparse-checkout-cone-mode: false
    - uses: aerospike/shared-workflows/.github/actions/collect-build-artifacts@v3
```

All inputs have defaults matching the standard pipeline conventions. If your build jobs upload artifacts as `build-artifacts-{distro}-{arch}`, this action works with no configuration.
