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
| `gh-workflows-ref`   | Git reference to checkout shared-workflows repository      | No       | `v2.0.2`                        |
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
      gh-workflows-ref: v2.0.2 # IMPORTANT: Set to match the ref in your 'uses:' line
      dry-run: false
```

## Important Notes

### gh-workflows-ref Parameter

**For external consumers**: When calling this workflow with a specific version (e.g., `@v2.0.3`), you should explicitly set `gh-workflows-ref: v2.0.3` to match the ref used in your `uses:` line. This ensures consistency between the workflow version and the entrypoint scripts version.

**Why this matters**: GitHub Actions doesn't provide access to the ref used in the `uses:` line from within the reusable workflow. If you don't set `gh-workflows-ref`, it will default to `v2.0.2`, which may not match the workflow version you're using, potentially causing inconsistencies.

**Example**: If calling `uses: aerospike/shared-workflows/.github/workflows/reusable_create-release-bundle.yaml@v2.0.3`, also set `gh-workflows-ref: v2.0.3`.

## Prerequisites

- JFrog Artifactory instance with OIDC authentication configured
- GitHub Actions with OIDC token access to Artifactory
- Existing builds in JFrog Artifactory that will be included in the bundle

## Testing

Run the basic test suite:

```bash
.github/workflows/create-release-bundle/test-entrypoint.sh
```
