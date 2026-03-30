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
| Generic (everything else) | `{project}-generic-dev-local` | `.asc`                     | `version`, `package_name`                                                          |

All types also include `build.type` and `internal` properties when those inputs are set.

## Adding a new artifact type

The deploy pipeline uses a centralized type registry (`type_registry.sh`). To add a new type:

1. Add entries to the config arrays in `type_registry.sh` (`TYPE_EXTENSIONS`, `TYPE_REPO`, `TYPE_COMPANIONS`, `TYPE_STRUCT_DIR`)
2. Add `type` to `UPLOAD_ORDER` (before `generic`)
3. Add a `get_TYPE_props()` function in `type_registry.sh`
4. Add a `process_TYPE()` function in `package_utils.sh` (or reuse `process_generic`)
5. Add tests

Simple types (like DEB/RPM) need no custom upload function -- the generic `upload_type()` dispatch handles them. Complex types that need special upload logic (like JAR's dedup or NuGet's path-based layout) define an `upload_TYPE_packages()` override in `entrypoint.sh`.

## Inputs

| Input                  | Description                                                                 | Required | Default                         |
| ---------------------- | --------------------------------------------------------------------------- | -------- | ------------------------------- |
| `jf-project`           | JFrog Artifactory project name                                              | Yes      | -                               |
| `jf-build-name`        | JFrog build name                                                            | Yes      | -                               |
| `jf-build-id`          | JFrog build ID for the overall build info                                   | Yes      | -                               |
| `jf-metadata-build-id` | JFrog build ID for the build metadata                                       | Yes      | -                               |
| `version`              | Version string for build info                                               | Yes      | -                               |
| `gh-workflows-ref`     | Git ref for shared-workflows (**must match `uses:`**)                       | Yes      | -                               |
| `build-type`           | Freeform label applied as `build.type` target-prop (e.g., release, nightly) | No       | `""`                            |
| `internal`             | Mark artifacts as internal-only (`internal=true` target-prop)               | No       | `false`                         |
| `dry-run`              | Show what would be uploaded without uploading                               | No       | `false`                         |
| `jar-group-id`         | Maven group ID fallback for JAR artifacts                                   | No       | `""`                            |
| `gh-artifact-name`     | Name of the artifacts to download                                           | No       | `signed-artifacts`              |
| `gh-checkout-path`     | Directory to checkout shared-workflows into                                 | No       | `shared-workflows`              |
| `gh-retention-days`    | Retention days for the artifacts                                            | No       | `1`                             |
| `jf-url`               | JFrog Artifactory URL                                                       | No       | `https://artifact.aerospike.io` |
| `oidc-provider-name`   | OIDC provider name for authentication                                       | No       | `gh-citrusleaf`                 |
| `oidc-audience`        | OIDC audience for authentication                                            | No       | `citrusleaf`                    |
| `runs-on`              | The runner to use                                                           | No       | `ubuntu-22.04`                  |

## Outputs

| Output        | Description       |
| ------------- | ----------------- |
| `jf-build-id` | The build ID used |

## How it works

### 1. Structuring phase

Artifacts arrive in `build-artifacts/` as a flat collection from the sign stage. The structuring phase categorizes them by type and gathers companion files:

- Each registered type's extension is matched
- Companion files (defined per type in `TYPE_COMPANIONS`) are automatically copied alongside their primary artifact
- Generic catches everything not claimed by a registered type

### 2. Upload phase

Each type directory is uploaded to its respective repository with appropriate properties. The upload functions are driven by the type registry:

- Simple types (DEB, RPM) use the generic `upload_type()` dispatch which calls `get_TYPE_props()` and `get_TYPE_extra_flags()` by convention
- Complex types (JAR, NuGet, generic) use custom upload functions
- All uploads go through `jf_upload()` which adds standard flags (`--flat=false`, `--build-name`, `--build-number`, `--project`)

### 3. Build info

After uploads, build info is published with parent-child relationships linking metadata builds and artifact builds.

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

## File layout

```text
deploy-artifacts/
  entrypoint.sh          # Main script: arg parsing, upload functions, orchestration
  type_registry.sh       # Type config arrays + per-type props/flags functions
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
