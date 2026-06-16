# Collect Build Artifacts

Download per-matrix build artifacts and merge them into a single artifact for downstream jobs (sign, deploy). This is the standard collect step in the composable pipeline pattern.

## Behavior

1. **Download** all artifacts matching the glob with **`merge-multiple: false`**, so each named artifact is extracted under its own subdirectory (see [download-artifact](https://github.com/actions/download-artifact)). That avoids concurrent unpack into the same basename, which can **corrupt** binary artifacts (for example invalid ZIPs / bad CRC inside wheels).
2. **Merge** every file under those subdirectories into one flat output directory using `merge_flat.sh` (`cp -p`, sequential). If two files would map to the same **basename**, the step **fails** with a clear message instead of silently overwriting.
3. **Upload** the flat directory as a single artifact (`output-name`, default `build-artifacts`).

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

Ensure matrix jobs do not emit different files with the **same filename** into their artifact directories; if they do, the collect step will error until filenames or layout are fixed.
