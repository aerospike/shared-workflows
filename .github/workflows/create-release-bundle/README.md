# Create Release Bundle Workflow

Create JFrog release bundles from a configurable list of build names.

## Overview

This workflow creates JFrog release bundles by bundling one or more builds into a single distributable package.

## Inputs

| Input                | Description                                                | Required | Default                         |
| -------------------- | ---------------------------------------------------------- | -------- | ------------------------------- |
| `jf-project`         | JFrog Artifactory project name                             | Yes      | -                               |
| `jf-build-names`     | Comma-separated list of build names to include             | Yes      | -                               |
| `jf-bundle-name`     | Name for the release bundle                                | Yes      | -                               |
| `version`            | Version of the release bundle                              | Yes      | -                               |
| `jf-url`             | JFrog Artifactory URL                                      | No       | `https://artifact.aerospike.io` |
| `oidc-provider-name` | OIDC provider name for authentication                      | No       | `gh-aerospike`                  |
| `oidc-audience`      | OIDC audience for authentication                           | No       | `aerospike`                     |
| `runs-on`            | The runner to use for the build                            | No       | `ubuntu-22.04`                  |
| `gh-checkout-path`   | Directory to checkout the shared-workflows repository into | No       | `shared-workflows`              |
| `gh-workflows-ref`   | Git ref for shared-workflows (**should match `uses:`**)    | Yes      | -                               |
| `dry-run`            | Whether to run in dry-run mode                             | No       | `false`                         |

## Example Usage

**Note**: The example below shows the pattern for external consumers using tagged versions. Internal workflows in this repository use relative paths (e.g., `uses: ./.github/workflows/reusable_create-release-bundle.yaml`) for development and testing.

### Basic release bundle creation

```yaml
name: Create Release Bundle
on:
  workflow_dispatch:
  push:
    tags: ["v*"]

jobs:
  create-release-bundle:
    uses: aerospike/shared-workflows/.github/workflows/reusable_create-release-bundle.yaml@v2.0.2
    with:
      jf-project: database
      jf-build-names: "database-build,client-build"
      jf-bundle-name: database-release
      version: ${{ github.ref_name }}
      gh-workflows-ref: v2.0.2 # Should match the version in your 'uses:' line
      dry-run: false
```

## Required: gh-workflows-ref

The `gh-workflows-ref` input is **required** and must match the version in your `uses:` line. See [Why gh-workflows-ref is required](../docs/why-gh-workflows-ref.md) for details.

## Prerequisites

- JFrog Artifactory instance with OIDC authentication configured
- GitHub Actions with OIDC token access to Artifactory
- Existing builds in JFrog Artifactory that will be included in the bundle

## Testing

Run the basic test suite:

```bash
.github/workflows/create-release-bundle/test-entrypoint.sh
```
