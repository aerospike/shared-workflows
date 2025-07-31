# Upload to JFrog Artifactory Workflow

A reusable GitHub Actions workflow for uploading artifacts to JFrog Artifactory following best practices for repository naming and organization.

## Overview

This workflow uploads build artifacts to JFrog Artifactory. It automatically categorizes files by type and uploads them to the appropriate repositories:

- **DEB packages** → `{project}-deb-dev-local`
- **RPM packages** → `{project}-rpm-dev-local`
- **Generic files** → `{project}-generic-dev-local`

With the structure

### Debian/Ubuntu

```text
dists/
├── bookworm/
│   └── main/
│       └── binary-amd64/
│           ├── Packages.gz
│           ├── Release
│           └── Release.gpg
├── bullseye/
│   └── main/
│       └── binary-amd64/
│           └── …
└── noble/
    └── main/
        └── binary-amd64/
            └── …
pool/
├── bookworm/
│   └── aerospike-server-community/
│       ├── aerospike-server-community_7.2.0.10-1debian12_amd64.deb
│       ├── aerospike-server-community_7.2.0.10-1debian12_amd64.deb.asc
│       ├── aerospike-server-community_7.2.0.10-1debian12_arm64.deb
│       ├── aerospike-server-community_7.2.0.10-1debian12_arm64.deb.asc
│       ├── aerospike-server-community_8.0.0.7-1debian12_amd64.deb
│       ├── aerospike-server-community_8.0.0.7-1debian12_amd64.deb.asc
│       ├── aerospike-server-community_8.0.0.7-1debian12_arm64.deb
│       └── aerospike-server-community_8.0.0.7-1debian12_arm64.deb.asc
├── bullseye/
│   └── aerospike-server-community/
│       ├── aerospike-server-community_7.2.0.10-1debian11_amd64.deb
│       ├── … (and corresponding `.asc`)
└── noble/
    └── aerospike-server-community/
        ├── aerospike-server-community_7.2.0.10-1ubuntu24.04_amd64.deb
        ├── … (and corresponding `.asc`)


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

## Inputs

| Input                            | Description                              | Required | Default |
| -------------------------------- | ---------------------------------------- | -------- | ------- |
| `repository`                     | JFrog Artifactory repository name        | Yes      | -       |
| `project`                        | Project name (used in repository naming) | Yes      | -       |
| `version`                        | Version string for build info            | Yes      | -       |
| `artifactory-url`                | JFrog Artifactory URL                    | Yes      | -       |
| `artifactory-oidc-provider-name` | OIDC provider name for authentication    | Yes      | -       |
| `artifactory-oidc-audience`      | OIDC audience for authentication         | Yes      | -       |
| `build-artifacts-name`           | Name of the artifacts to download        | Yes      | -       |

## Secrets

| Secret                   | Description                               | Required |
| ------------------------ | ----------------------------------------- | -------- |
| `artifactory-oidc-token` | OIDC token for Artifactory authentication | Yes      |

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
      repository: database-deb-dev-local
      project: database
      version: ${{ github.ref_name }}
      artifactory-url: https://aerospike.jfrog.io/artifactory
      artifactory-oidc-provider-name: github-actions
      artifactory-oidc-audience: https://aerospike.jfrog.io/artifactory
      build-artifacts-name: build-artifacts
    secrets:
      artifactory-oidc-token: ${{ secrets.ARTIFACTORY_OIDC_TOKEN }}
```

### Build Info Publishing

After uploading artifacts, the workflow publishes comprehensive build information:

- Environment variables
- Git information
- Dependencies
- Build metadata

### Repository Structure

Following JFrog best practices, artifacts are organized by:

- **Project**: Your project identifier (e.g., "database")
- **Technology**: Package type (deb, rpm, generic)
- **Maturity**: Environment level (dev, stage, prod)
- **Locator**: Physical location (local)

## Prerequisites

- JFrog Artifactory instance with OIDC authentication configured
- GitHub Actions with OIDC token access to Artifactory
- Build artifacts available as downloadable artifacts from a previous job

## Notes

- The workflow expects artifacts to be in a directory called `build-artifacts`
- All uploads use the "DEV" environment level and "local" locator
- Build info is published for each artifact type separately
- The workflow follows JFrog's recommended repository naming conventions
