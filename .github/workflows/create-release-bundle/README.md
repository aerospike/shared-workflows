# Create Release Bundle Workflow

Create JFrog release bundles from a configurable list of build names.

## Overview

This workflow creates JFrog release bundles by bundling one or more builds into a single distributable package.

## Inputs

| Input                            | Description                                    | Required | Default                      |
| -------------------------------- | ---------------------------------------------- | -------- | ---------------------------- |
| `project`                        | JFrog Artifactory project name                 | Yes      | -                            |
| `build-names`                    | Comma-separated list of build names to include | Yes      | -                            |
| `bundle-name`                    | Name for the release bundle                    | Yes      | -                            |
| `version`                        | Version of the release bundle                  | Yes      | -                            |
| `artifactory-url`                | JFrog Artifactory URL                          | No       | `https://aerospike.jfrog.io` |
| `artifactory-oidc-provider-name` | OIDC provider name for authentication          | No       | `gh-aerospike`               |
| `artifactory-oidc-audience`      | OIDC audience for authentication               | No       | `aerospike`                  |
| `retention-days`                 | Retention days for the release bundle          | No       | `30`                         |
| `dry-run`                        | Whether to run in dry-run mode                 | No       | `false`                      |

## Example Usage

### Basic release bundle creation

```yaml
name: Create Release Bundle
on:
  workflow_dispatch:
  push:
    tags: ["v*"]

jobs:
  create-release-bundle:
    uses: ./.github/workflows/reusable_create-release-bundle.yaml
    with:
      project: database
      build-names: "database-build,client-build"
      bundle-name: database-release
      version: ${{ github.ref_name }}
      retention-days: 90
      dry-run: false
```

## Prerequisites

- JFrog Artifactory instance with OIDC authentication configured
- GitHub Actions with OIDC token access to Artifactory
- Existing builds in JFrog Artifactory that will be included in the bundle

## Notes

- The workflow follows the established patterns from other shared workflows

## Testing

Run the basic test suite:

```bash
.github/workflows/create-release-bundle/test-entrypoint.sh
```

The test suite validates:

- Basic release bundle creation with multiple builds
- Dry-run mode functionality
- Error handling
- Single build scenarios

The test suite will create temporary test scenarios and verify all functionality works correctly.

## Integration

This workflow is designed to be used as part of larger CI/CD pipelines:

1. **Build Phase**: Use build-artifacts workflow to create builds
2. **Sign Phase**: Gpg sign build-artifacts
3. **Upload Phase**: Use upload-artifacts workflow to upload to JFrog
4. **Bundle Phase**: Use this workflow to create release bundles

```yaml
jobs:
  build:
    uses: ./.github/workflows/reusable_execute-build.yaml
    with:
      build-script: ./build.sh
      artifact-directory: dist

  upload:
    needs: build
    uses: ./.github/workflows/reusable_upload-artifacts.yaml
    with:
      project: my-project
      build-name: my-build
      version: v1.0.0

  create-release-bundle:
    needs: upload
    uses: ./.github/workflows/reusable_create-release-bundle.yaml
    with:
      project: my-project
      build-names: "my-build-deb,my-build-rpm"
      bundle-name: my-release
      version: v1.0.0
```
