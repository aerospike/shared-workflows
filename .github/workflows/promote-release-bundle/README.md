# Promote Release Bundle Workflow

## Inputs

| Input                | Description                    | Required | Default                         |
| -------------------- | ------------------------------ | -------- | ------------------------------- |
| `jf-project`         | JFrog Artifactory project name | Yes      | -                               |
| `jf-bundle-name`     | Name for the release bundle    | Yes      | -                               |
| `version`            | Version of the release bundle  | Yes      | -                               |
| `new-environment`    | Environment to promote to      | Yes      | -                               |
| `dry-run`            | Whether to run in dry-run mode | No       | false                           |
| `jf-url`             | JFrog Artifactory URL          | No       | `https://artifact.aerospike.io` |
| `oidc-audience`      | OIDC audience                  | No       | aerospike                       |
| `oidc-provider-name` | OIDC provider name             | No       | gh-aerospike                    |

## Example Usage

**Note**: The example below shows the pattern for external consumers using tagged versions. Internal workflows in this repository use relative paths (e.g., `uses: ./.github/workflows/reusable_create-release-bundle.yaml`) for development and testing.

### Basic release bundle promotion

```yaml
name: Promote Release Bundle
on:
  workflow_dispatch:
  push:
    tags: ["v*"]

jobs:
  promote-release-bundle:
    uses: aerospike/shared-workflows/.github/workflows/reusable_promote-release-bundle.yaml@v4.0.0
    with:
      jf-project: database
      jf-bundle-name: database-release
      version: ${{ github.ref_name }}
      new-environment: STAGE
      gh-workflows-ref: v4.0.0 # Should match the version in your 'uses:' line
```

## Required: gh-workflows-ref

The `gh-workflows-ref` input is **required** and must match the version in your `uses:` line. See [Why gh-workflows-ref is required](../docs/why-gh-workflows-ref.md) for details.

## Permissions

Workflow-level permissions are `id-token: write`.

```yaml
permissions:
  id-token: write
```

## Prerequisites

- JFrog Artifactory instance with OIDC authentication configured
- GitHub Actions with OIDC token access to Artifactory
- Existing JFrog release bundle
