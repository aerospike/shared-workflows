# Upload to JFrog Artifactory Workflow

> **Note:** This workflow is used internally by [`reusable_artifacts-cicd.yaml`](../artifacts-cicd/README.md). Most consumers should use the orchestrator rather than calling this directly.

A reusable GitHub Actions workflow for uploading build artifacts to JFrog Artifactory. It automatically categorizes files by type, gathers companion files (signatures, POMs), and uploads them to the appropriate repositories with metadata properties.

## Supported artifact types

| Type                      | Repository                    | Companion files            | Properties                                                                         |
| ------------------------- | ----------------------------- | -------------------------- | ---------------------------------------------------------------------------------- |
| DEB                       | `{project}-deb-dev-local`     | `.asc`                     | `version`, `package_name`, `deb.distribution`, `deb.component`, `deb.architecture` |
| RPM                       | `{project}-rpm-dev-local`     | `.asc`                     | `version`, `package_name`, `rpm.distribution`, `rpm.component`, `rpm.architecture` |
| JAR                       | `{project}-maven-dev-local`   | `.pom`, `.asc`, `.pom.asc` | `version`, `group_id`, `package_name`                                              |
| NuGet (.nupkg/.snupkg)    | `{project}-nuget-dev-local`   | `.asc`                     | `version`, `package_name`                                                          |
| npm (.tgz)                | `{project}-npm-dev-local`     | `.asc`                     | `version`, `package_name`                                                          |
| PyPI (.whl/.tar.gz sdist) | `{project}-pypi-dev-local`    | `.asc`                     | `version`, `package_name`, `pypi.name`, `pypi.version`                             |
| Go module (.zip)          | `{project}-go-dev-local`      | `.asc`                     | `version`, `package_name`, `go.module`, `go.version`                               |
| Helm chart (.tgz)         | `{project}-helm-dev-local`    | `.prov`                    | `version`, `package_name`, `helm.name`, `helm.version`                             |
| Windows (.exe/.msi/.msix) | `{project}-generic-dev-local` | `.asc`                     | `version`, `package_name` (same repo as generic)                                   |
| Generic (everything else) | `{project}-generic-dev-local` | `.asc`                     | `version`, `package_name`                                                          |

All types also include `build.type` and `internal` properties when those inputs are set.

## Adding a new artifact type

The deploy pipeline uses a centralized type registry (`type_registry.sh`). To add a new type:

1. Call `register_type` in `type_registry.sh` with `--extension` (single `find -name` glob) or `--extensions` (comma-separated globs, e.g. `*.whl,*.tar.gz`), plus `--repo`, companions, etc.
2. Add `type` to `UPLOAD_ORDER` (before `generic`)
3. Add a `get_TYPE_props()` function in `type_registry.sh`
4. Add a `process_TYPE()` function in `package_utils.sh` (or reuse `process_generic`)
5. Add tests

**Simple types** (like DEB/RPM) with unique extensions need no custom upload function. The generic `upload_type()` dispatch handles them.

**Types with ambiguous extensions** (like npm and PyPI, which share `.tgz`/`.tar.gz` with generic tarballs) also need:

- A content-detection function (e.g., `is_npm_package`, `is_pypi_package`) in `type_detection.sh` (after `package_utils.sh` for shared helpers)
- A detector entry in the unified tarball content-detection block in `entrypoint.sh`'s `structure_build_artifacts()`
- The ambiguous extension added to `get_known_extensions()` if not already covered by `TYPE_EXTENSIONS`

**Types with custom path layouts** (JAR, NuGet, npm, PyPI) define an `upload_TYPE_packages()` override in `entrypoint.sh` instead of using the generic dispatch.

## Inputs

| Input                              | Description                                                                                                                                                                                          | Required | Default                         |
| ---------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | ------------------------------- |
| `jf-project`                       | JFrog Artifactory project name                                                                                                                                                                       | Yes      | -                               |
| `jf-build-name`                    | JFrog build name                                                                                                                                                                                     | Yes      | -                               |
| `jf-build-id`                      | JFrog build ID for the overall build info                                                                                                                                                            | Yes      | -                               |
| `jf-metadata-build-id`             | Build ID prefix used to discover child build-infos for aggregation (searches for `<prefix>*.json`). When empty, child build-info aggregation is skipped and only the parent build-info is published. | No       | `""`                            |
| `version`                          | Version string for build info                                                                                                                                                                        | Yes      | -                               |
| `gh-workflows-ref`                 | Git ref for shared-workflows (**must match `uses:`**)                                                                                                                                                | Yes      | -                               |
| `build-type`                       | Freeform label applied as `build.type` target-prop (e.g., release, nightly)                                                                                                                          | No       | `""`                            |
| `internal`                         | Mark artifacts as internal-only (`internal=true` target-prop)                                                                                                                                        | No       | `false`                         |
| `skip-publish-build-info`            | Upload artifacts only; defer build-info publish to a later job (parallel platform deploys)                                                                                                           | No       | `false`                         |
| `publish-build-info-only`            | Publish parent build-info only after parallel upload jobs; skips artifact download/upload                                                                                                            | No       | `false`                         |
| `dry-run`                          | Show what would be uploaded without uploading                                                                                                                                                        | No       | `false`                         |
| `jar-group-id`                     | Maven group ID fallback for JAR artifacts                                                                                                                                                            | No       | `""`                            |
| `gh-artifact-name`                 | Name of the artifacts to download                                                                                                                                                                    | No       | `signed-artifacts`              |
| `gh-checkout-path`                 | Directory to checkout shared-workflows into                                                                                                                                                          | No       | `shared-workflows`              |
| `gh-retention-days`                | Retention days for the artifacts                                                                                                                                                                     | No       | `1`                             |
| `jf-url`                           | JFrog Artifactory URL                                                                                                                                                                                | No       | `https://artifact.aerospike.io` |
| `oidc-provider-name`               | OIDC provider name for authentication                                                                                                                                                                | No       | `gh-aerospike`                  |
| `oidc-audience`                    | OIDC audience for authentication                                                                                                                                                                     | No       | `aerospike`                     |
| `runs-on`                          | The runner to use                                                                                                                                                                                    | No       | `ubuntu-22.04`                  |
| `gh-upload-bundle-metadata`        | When true and `structured_build_artifacts/.maven-bundle-metadata.json` exists after deploy, upload it as a workflow artifact for downstream jobs (e.g. release bundle annotate).                     | No       | `true`                          |
| `gh-bundle-metadata-artifact-name` | GitHub artifact name for the uploaded `.maven-bundle-metadata.json`.                                                                                                                                 | No       | `bundle-metadata`               |

## Outputs

| Output                          | Description                                                                                                                                                |
| ------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `jf-build-id`                   | The build ID used                                                                                                                                          |
| `bundle-metadata-artifact-name` | Artifact name to pass to `reusable_create-release-bundle` as `gh-bundle-metadata-artifact-name` when `bundle-metadata-available` is true; otherwise empty. |
| `bundle-metadata-available`     | `true` when Maven bundle metadata was uploaded as a GitHub artifact.                                                                                       |

## How it works

### 1. Structuring phase

Artifacts arrive in `build-artifacts/` as a flat collection from the sign stage. The structuring phase categorizes them by type and gathers companion files:

- Types with unique extensions (DEB, RPM, JAR, NuGet, `.whl`, Windows `.exe`/`.msi`/`.msix`) are matched by extension
- Gzipped tarballs (`.tgz` and `.tar.gz`) and zip archives (`.zip`) are inspected with content-based detectors to distinguish npm packages, PyPI source distributions, Go modules, Helm charts (`.tgz` containing `Chart.yaml`), and generic archives
- Companion files (defined per type in `TYPE_COMPANIONS`) are automatically copied alongside their primary artifact
- Generic catches everything not claimed by the above

### 2. Upload phase

Each type directory is uploaded to its respective repository with appropriate properties. The upload functions are driven by the type registry:

- Simple types (DEB, RPM) use the generic `upload_type()` dispatch which calls `get_TYPE_props()` and `get_TYPE_extra_flags()` by convention
- Types with custom path layouts (JAR, NuGet, npm, PyPI, Go, win, generic) define `upload_TYPE_*` overrides in `entrypoint.sh`
- All uploads go through `jf_upload()` or `run jf rt upload` which adds standard flags (`--build-name`, `--build-number`, `--project`)

### 3. Build info

After uploads, build info is published with parent-child relationships linking metadata builds and artifact builds.

#### Parallel platform deploys (one parent build-info)

When artifacts are uploaded from multiple jobs (e.g. Linux, macOS, Windows) that share the same `jf-build-id`:

1. Each platform job calls this workflow with `skip-publish-build-info: true` and an empty `jf-metadata-build-id`.
2. All uploads tag the same artifact child build number (`{jf-build-id}-artifacts`).
3. A final job calls this workflow with `publish-build-info-only: true` and `jf-metadata-build-id` set to the build-phase prefix (e.g. `{jf-build-id}-buildinfo`) so metadata children are discovered and appended once.

## Directory structure after structuring

### DEB

```text
deb/pool/
  jammy/{package-name}/{file}.deb
  jammy/{package-name}/{file}.deb.asc
  bookworm/{package-name}/{file}.deb
  bookworm/{package-name}/{file}.deb.asc
```

### RPM

```text
rpm/
  el9/x86_64/{file}.rpm
  el9/x86_64/{file}.rpm.asc
  amzn2023/aarch64/{file}.rpm
```

### JAR/Maven

```text
jar/
  com/example/project/{artifact}/{version}/{artifact}.jar
  com/example/project/{artifact}/{version}/{artifact}.pom
  com/example/project/{artifact}/{version}/{artifact}.jar.asc
```

### NuGet

```text
nupkg/
  {PackageName}.{Version}.nupkg
  {PackageName}.{Version}.nupkg.asc
  {PackageName}.{Version}.snupkg
```

### npm

```text
npm/
  {filename}.tgz
  {filename}.tgz.asc
```

### PyPI

`.whl` files are routed by extension. `.tar.gz` files are inspected for a root-level `PKG-INFO` to distinguish Python source distributions from generic tarballs (the same content-based detection pattern used for npm `.tgz` files).

```text
pypi/
  {filename}.whl
  {filename}.whl.asc
  {filename}.tar.gz
  {filename}.tar.gz.asc
```

### Go module

`.zip` files are inspected for Go module layout (`module@version/go.mod`). At upload time, the `.mod` file is extracted from the zip and a `.info` JSON is generated, following the [GOPROXY protocol](https://go.dev/ref/mod#goproxy-protocol).

```text
go/
  {filename}.zip
  {filename}.zip.asc
```

Uploaded to JFrog as:

```text
{project}-go-dev-local/
  {module}/@v/{version}.zip
  {module}/@v/{version}.zip.asc
  {module}/@v/{version}.mod
  {module}/@v/{version}.info
```

### Helm chart

`.tgz` files are inspected for a top-level `Chart.yaml` (with `apiVersion`, `name`, `version`) to distinguish packaged Helm charts from npm/generic tarballs. The chart's `.prov` provenance file (produced by the sign stage) is gathered as the companion instead of a `.asc`.

```text
helm/
  {chart}-{version}.tgz
  {chart}-{version}.tgz.prov
```

### Windows

`.exe`, `.msi`, and `.msix` files are matched by extension and uploaded to the generic repository.

```text
win/
  {filename}.exe
  {filename}.exe.asc
```

## File layout

```text
deploy-artifacts/
  entrypoint.sh          # Main script: arg parsing, upload functions, orchestration
  type_registry.sh       # Type config arrays + per-type props/flags functions
  type_detection.sh      # Content-based detection predicates (is_npm_package, is_helm_chart, etc.)
  detect_types.sh        # Standalone detection entrypoint (used by the detect-artifacts action); writes
                         # structured_build_artifacts/.maven-bundle-metadata.json (Maven GAV scan)
  upload_utils.sh        # Shared helpers: jf_upload, upload_companions, discover_and_process, upload_type
  package_utils.sh       # Metadata extraction + process_* functions for structuring
  create-test-fixtures.sh
  tests/
    bats/                # Bats test files
    helpers/             # Test setup, command parsers, assertions
```

## Required: gh-workflows-ref

The `gh-workflows-ref` input is **required** and must match the version in your `uses:` line. See [Why gh-workflows-ref is required](../docs/why-gh-workflows-ref.md) for details.

## Prerequisites

- JFrog Artifactory instance with OIDC authentication configured
- GitHub Actions with OIDC token access to Artifactory
- Build artifacts available as downloadable artifacts
