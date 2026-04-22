# Detect artifact types

Runs [`detect_types.sh`](../../workflows/deploy-artifacts/detect_types.sh): content-based detection for ambiguous archives (npm tarballs, PyPI sdists, Go module zips) and writes `structured_build_artifacts/` plus a manifest, matching the deploy entrypoint’s detection phase. JFrog/build metadata is not required because detection only inspects file contents and copies into the structured tree.

## Prerequisites

- Merged build tree on disk (for example from [`collect-build-artifacts`](../collect-build-artifacts) or a `download-artifact` step with the same layout).
- `detect_types.sh` and sibling scripts (`package_utils.sh`, `type_registry.sh`, `upload_utils.sh`, `type_detection.sh`) available. Checkout **shared-workflows** at `gh-workflows-ref` (full or sparse-checkout including `.github/workflows/deploy-artifacts/`).

Runner tools used by detectors: `jq`, `tar`, `unzip` (typical GitHub-hosted Ubuntu images include these).

## Inputs

| Input           | Required | Default                                              | Description                            |
| --------------- | -------- | ---------------------------------------------------- | -------------------------------------- |
| `script-path`   | No       | `.github/workflows/deploy-artifacts/detect_types.sh` | Path to `detect_types.sh`              |
| `artifacts-dir` | No       | `build-artifacts`                                    | Root directory to scan                 |
| `working-dir`   | No       | _(empty)_                                            | If set, `--working-dir` for the script |

## Outputs

| Output                     | Description                                                                                                                                                                                       |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `structured-artifacts-dir` | Relative path to `structured_build_artifacts/` (per-type subdirs and copied files). If `working-dir` is set, this path is rooted under that directory (e.g. `my-job/structured_build_artifacts`). |
| `manifest-path`            | Relative path to the TSV manifest (`.manifest`): one row per primary artifact with columns `path` and `type`. Companion files are gathered on disk but not listed here.                           |

In the calling workflow, give the `uses` step an `id` (for example `id: detect-artifacts`), then reference `${{ steps.detect-artifacts.outputs.structured-artifacts-dir }}` and `${{ steps.detect-artifacts.outputs.manifest-path }}`. You can also forward them from `jobs.<job_id>.outputs`.

## Example (after collect, before release bundle)

```yaml
steps:
  - uses: actions/checkout@v4
    with:
      repository: aerospike/shared-workflows
      ref: ${{ inputs.gh-workflows-ref }}
      path: shared-workflows
  - uses: actions/download-artifact@v4
    with:
      name: build-artifacts
      path: build-artifacts
  - id: detect-artifacts
    uses: aerospike/shared-workflows/.github/actions/detect-artifacts@v3
    with:
      script-path: shared-workflows/.github/workflows/deploy-artifacts/detect_types.sh
  - name: Detected artifacts
    run: |
      echo "Structured dir: ${{ steps.detect-artifacts.outputs.structured-artifacts-dir }}"
      echo "Manifest: ${{ steps.detect-artifacts.outputs.manifest-path }}"
```

See [`reusable_artifacts-cicd.yaml`](../../workflows/reusable_artifacts-cicd.yaml) for an integrated job between matrix collect and sign.
