# Upload to JFrog Artifactory Workflow

A reusable GitHub Actions workflow for uploading artifacts to JFrog Artifactory following best practices for repository naming and organization.

## Overview

This workflow uploads build artifacts to JFrog Artifactory. It automatically categorizes files by type and uploads them to the appropriate repositories:

- **DEB packages** → `{project}-deb-dev-local`
- **RPM packages** → `{project}-rpm-dev-local`
- **Generic files** → `{project}-generic-dev-local`

The workflow processes artifacts from a `build-artifacts` directory and creates structured build artifacts before uploading.

## Inputs

| Input                  | Description                                                | Required | Default                         |
| ---------------------- | ---------------------------------------------------------- | -------- | ------------------------------- |
| `jf-project`           | JFrog Artifactory project name                             | Yes      | -                               |
| `jf-build-name`        | JFrog build name                                           | Yes      | -                               |
| `jf-build-id`          | JFrog build ID for the overall build info                  | Yes      | -                               |
| `jf-metadata-build-id` | JFrog build ID for the build metadata                      | Yes      | -                               |
| `version`              | Version string for build info                              | Yes      | -                               |
| `jf-url`               | JFrog Artifactory URL                                      | No       | `https://artifact.aerospike.io` |
| `oidc-provider-name`   | OIDC provider name for authentication                      | No       | `gh-citrusleaf`                 |
| `oidc-audience`        | OIDC audience for authentication                           | No       | `citrusleaf`                    |
| `gh-artifact-name`     | Name of the artifacts to download                          | No       | `signed-artifacts`              |
| `gh-retention-days`    | Retention days for the artifacts                           | No       | `1`                             |
| `runs-on`              | The runner to use for the build                            | No       | `ubuntu-22.04`                  |
| `gh-checkout-path`     | Directory to checkout the shared-workflows repository into | No       | `shared-workflows`              |
| `gh-workflows-ref`     | Git reference to checkout shared-workflows repository      | No       | `v2.0.2`                        |
| `dry-run`              | Whether to run in dry-run mode                             | No       | `false`                         |

## Outputs

| Output        | Description       |
| ------------- | ----------------- |
| `jf-build-id` | The build ID used |

## Structure

### Debian/Ubuntu

```text
pool/
├── bookworm/
│   └── {package-name}/
│       ├── {package-name}_version_debian12_arch.deb
│       └── {package-name}_version_debian12_arch.deb.asc
├── bullseye/
│   └── {package-name}/
│       └── {package-name}_version_debian11_arch.deb
├── jammy/
│   └── {package-name}/
│       └── {package-name}_version_ubuntu22.04_arch.deb
└── noble/
    └── {package-name}/
        └── {package-name}_version_ubuntu24.04_arch.deb
```

### RPM/Yum

```text
repo/
├── el8/
│   ├── x86_64/
│   │   ├── *.rpm
│   │   └── repodata/
│   └── aarch64/
│       ├── *.rpm
│       └── repodata/
├── el9/
│   └── …
└── amzn2023/
    └── …
```

## Example Usage

**Note**: The example below shows the pattern for external consumers using tagged versions. Internal workflows in this repository use relative paths (e.g., `uses: ./.github/workflows/reusable_deploy-artifacts.yaml`) for development and testing.

```yaml
name: Upload to Artifactory
on:
  workflow_dispatch:
  push:
    tags: ["v*"]

jobs:
  upload:
    uses: aerospike/shared-workflows/.github/workflows/reusable_deploy-artifacts.yaml@v2.0.2
    with:
      jf-project: database
      jf-build-name: database
      jf-build-id: 1234567890
      jf-metadata-build-id: 1234567890-metadata
      version: ${{ github.ref_name }}
      jf-url: https://artifact.aerospike.io
      oidc-provider-name: gh-citrusleaf
      oidc-audience: citrusleaf
      gh-artifact-name: signed-artifacts
      gh-retention-days: 1
      gh-workflows-ref: v2.0.2 # IMPORTANT: Set to match the ref in your 'uses:' line
      dry-run: false
```

## Important Notes

### gh-workflows-ref Parameter

**For external consumers**: When calling this workflow with a specific version (e.g., `@v2.0.3`), you should explicitly set `gh-workflows-ref: v2.0.3` to match the ref used in your `uses:` line. This ensures consistency between the workflow version and the entrypoint scripts version.

**Why this matters**: GitHub Actions doesn't provide access to the ref used in the `uses:` line from within the reusable workflow. If you don't set `gh-workflows-ref`, it will default to `v2.0.2`, which may not match the workflow version you're using, potentially causing inconsistencies.

### Build Info Publishing

After uploading artifacts, the workflow publishes comprehensive build information:

## Prerequisites

- JFrog Artifactory instance with OIDC authentication configured
- GitHub Actions with OIDC token access to Artifactory
- Build artifacts available as downloadable artifacts

## Notes

- All uploads use the "DEV" environment level and "local" locator
- The workflow processes DEB and RPM files and creates structured build artifacts before uploading
