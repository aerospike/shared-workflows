# Detect artifact types

Runs [`detect_types.sh`](../../workflows/deploy-artifacts/detect_types.sh): content-based detection for ambiguous archives (npm tarballs, PyPI sdists, Go module zips, Helm charts) plus structured passes for PyPI wheels, NuGet packages, Maven POMs, and Docker bundle metadata, and writes `structured_build_artifacts/` plus a manifest, matching the deploy entrypoint’s detection phase. After scanning, it writes **`.maven-bundle-metadata.json`** (unique Maven GAV count, multi-package flag, aggregator presence, flatten heuristics) under the same structured directory. JFrog/build metadata is not required because detection only inspects file contents and copies into the structured tree.

## Prerequisites

- Merged build tree on disk (for example from [`collect-build-artifacts`](../collect-build-artifacts) or a `download-artifact` step with the same layout).
- `detect_types.sh` and its sibling scripts (`package_utils.sh`, `type_registry.sh`, `upload_utils.sh`, `type_detection.sh`) plus `../lib/helm-helpers.sh` (sourced for Helm chart detection) available. Checkout **shared-workflows** at `gh-workflows-ref` (full or sparse-checkout including both `.github/workflows/deploy-artifacts/` and `.github/workflows/lib/`).

Runner tools used by detectors: `jq`, `tar`, `unzip`, `xmllint` (for Maven POM detection). Typical GitHub-hosted Ubuntu images include these.

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
| `bundle-metadata-path`     | Relative path to `.maven-bundle-metadata.json`: Maven-only scan of all `*.pom` under the artifacts root (`is_multi_package`, `maven_module_count`, `maven_aggregator_present`, `is_flattened`).   |

After detection, `.maven-bundle-metadata.json` can be passed to [create-release-bundle](../create-release-bundle/README.md) as `bundle-metadata-path` so those fields are set on the release bundle version (`jf release-bundle-annotate`).

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
