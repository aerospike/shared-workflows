# Detect artifact types

Runs [`detect_types.sh`](../../workflows/deploy-artifacts/detect_types.sh): content-based detection for ambiguous archives (npm tarballs, PyPI sdists, Go module zips) and writes `structured_build_artifacts/` plus a manifest, matching the deploy entrypoint’s detection phase.

## Prerequisites

- Merged build tree on disk (for example from [`collect-build-artifacts`](../collect-build-artifacts) or a `download-artifact` step with the same layout).
- `detect_types.sh` and sibling scripts (`package_utils.sh`, `type_registry.sh`, `upload_utils.sh`, `type_detection.sh`) available. Checkout **shared-workflows** at `gh-workflows-ref` (full or sparse-checkout including `.github/workflows/deploy-artifacts/`).

Runner tools used by detectors: `jq`, `tar`, `unzip` (typical GitHub-hosted Ubuntu images include these).

## Inputs

| Input           | Required | Default                                              | Description                            |
| --------------- | -------- | ---------------------------------------------------- | -------------------------------------- |
| `jf-project`    | Yes      |                                                      | JFrog project                          |
| `jf-build-name` | Yes      |                                                      | JFrog build name                       |
| `version`       | Yes      |                                                      | Artifact version                       |
| `jf-build-id`   | Yes      |                                                      | Build ID / number for structuring      |
| `script-path`   | No       | `.github/workflows/deploy-artifacts/detect_types.sh` | Path to `detect_types.sh`              |
| `artifacts-dir` | No       | `build-artifacts`                                    | Root directory to scan                 |
| `working-dir`   | No       | _(empty)_                                            | If set, `--working-dir` for the script |
| `jar-group-id`  | No       | _(empty)_                                            | Maven group ID fallback                |
| `build-type`    | No       | _(empty)_                                            | `build.type` target-prop label         |
| `internal`      | No       | `false`                                              | Set `true` to pass `--internal`        |
| `dry-run`       | No       | `false`                                              | Pass `--dry-run`                       |

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
  - uses: aerospike/shared-workflows/.github/actions/detect-artifacts@v3
    with:
      jf-project: my-project
      jf-build-name: my-build
      version: 1.2.3
      jf-build-id: ${{ github.run_id }}
      script-path: shared-workflows/.github/workflows/deploy-artifacts/detect_types.sh
```

See [`reusable_artifacts-cicd.yaml`](../../workflows/reusable_artifacts-cicd.yaml) for an integrated job between matrix collect and sign.
