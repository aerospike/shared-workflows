# Upload to JFrog Artifactory Workflow

A reusable GitHub Actions workflow for uploading artifacts to JFrog Artifactory following best practices for repository naming and organization.

## Overview

This workflow uploads build artifacts to JFrog Artifactory. It automatically categorizes files by type and uploads them to the appropriate repositories:

- **DEB packages** → `{project}-deb-dev-local`
- **RPM packages** → `{project}-rpm-dev-local`
- **Generic files** → `{project}-generic-dev-local`

The workflow processes artifacts from a `build-artifacts` directory and creates structured build artifacts before uploading.

## Inputs

| Input                            | Description                           | Required | Default                      |
| -------------------------------- | ------------------------------------- | -------- | ---------------------------- |
| `project`                        | JFrog Artifactory project name        | Yes      | -                            |
| `build-name`                     | Name for the unified build            | Yes      | -                            |
| `version`                        | Version string for build info         | Yes      | -                            |
| `artifactory-url`                | JFrog Artifactory URL                 | No       | `https://aerospike.jfrog.io` |
| `artifactory-oidc-provider-name` | OIDC provider name for authentication | No       | `gh-citrusleaf`              |
| `artifactory-oidc-audience`      | OIDC audience for authentication      | No       | `citrusleaf`                 |
| `artifact-name`                  | Name of the artifacts to download     | No       | `build-artifacts`            |
| `retention-days`                 | Retention days for the artifacts      | No       | `1`                          |
| `dry-run`                        | Whether to run in dry-run mode        | No       | `false`                      |

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

```yaml
name: Upload to Artifactory
on:
  workflow_dispatch:
  push:
    tags: ["v*"]

jobs:
  upload:
    uses: ./.github/workflows/reusable_upload-artifacts.yaml
    with:
      project: database
      build-name: database
      version: ${{ github.ref_name }}
      artifactory-url: https://aerospike.jfrog.io
      artifactory-oidc-provider-name: gh-citrusleaf
      artifactory-oidc-audience: citrusleaf
      artifact-name: build-artifacts
      retention-days: 1
      dry-run: false
```

### Build Info Publishing

After uploading artifacts, the workflow publishes comprehensive build information:

## Prerequisites

- JFrog Artifactory instance with OIDC authentication configured
- GitHub Actions with OIDC token access to Artifactory
- Build artifacts available as downloadable artifacts

## Notes

- The workflow expects artifacts to be in a directory called `build-artifacts`
- All uploads use the "DEV" environment level and "local" locator
- Build info is published once after all artifacts are uploaded
- The workflow processes DEB and RPM files and creates structured build artifacts before uploading
- Generic files are uploaded directly without structured processing
