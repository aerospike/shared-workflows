# Upload to JFrog Artifactory Workflow

A reusable GitHub Actions workflow for uploading artifacts to JFrog Artifactory following best practices for repository naming and organization.

## Overview

This workflow uploads build artifacts to JFrog Artifactory using the recommended naming convention: `<projectKey>-<tech>-<maturity>-<locator>`. It automatically categorizes files by type and uploads them to the appropriate repositories:

- **DEB packages** → `{project}-deb-dev-local`
- **RPM packages** → `{project}-rpm-dev-local`
- **Generic files** → `{project}-generic-dev-local`

## Inputs

| Input                            | Description                                | Required | Default |
| -------------------------------- | ------------------------------------------ | -------- | ------- |
| `repository`                     | JFrog Artifactory repository name          | Yes      | -       |
| `project`                        | Project name (used in repository naming)   | Yes      | -       |
| `version`                        | Version string for build info              | Yes      | -       |
| `artifactory-url`                | JFrog Artifactory URL                      | Yes      | -       |
| `artifactory-oidc-provider-name` | OIDC provider name for authentication      | Yes      | -       |
| `artifactory-oidc-audience`      | OIDC audience for authentication           | Yes      | -       |
| `build-artifacts-name`           | Name of the artifacts to download          | Yes      | -       |
| `artifacts-glob`                 | Glob pattern to match artifacts for upload | Yes      | -       |

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
      artifacts-glob: "**/*.{deb,rpm,jar,tar.gz}"
    secrets:
      artifactory-oidc-token: ${{ secrets.ARTIFACTORY_OIDC_TOKEN }}
```

## Features

### Automatic File Type Detection

The workflow automatically detects and categorizes files:

- **DEB packages**: Extracts metadata (package name, architecture, codename) and uploads with proper Debian repository structure
- **RPM packages**: Extracts metadata (package name, version, architecture, distribution) and uploads with proper RPM repository structure
- **Generic files**: Any other files are uploaded to the generic repository

### Signature and Checksum Support

For each uploaded file, the workflow also uploads:

- GPG signatures (`.asc` files)
- SHA256 checksums (`.sha256` files)
- Signature checksums (`.asc.sha256` files)

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

## Output

The workflow uploads artifacts to three separate repositories:

- `{project}-deb-dev-local` - Debian packages
- `{project}-rpm-dev-local` - RPM packages
- `{project}-generic-dev-local` - Generic files

Each repository contains:

- The original artifacts
- GPG signatures (if available)
- SHA256 checksums
- Build information for tracking and compliance

## Prerequisites

- JFrog Artifactory instance with OIDC authentication configured
- GitHub Actions with OIDC token access to Artifactory
- Build artifacts available as downloadable artifacts from a previous job

## Notes

- The workflow expects artifacts to be in a directory called `build-artifacts`
- All uploads use the "dev" maturity level and "local" locator
- Build info is published for each artifact type separately
- The workflow follows JFrog's recommended repository naming conventions
