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

### Basic release bundle promotion

```yaml
name: Promote Release Bundle
on:
  workflow_dispatch:
  push:
    tags: ["v*"]

jobs:
  promote-release-bundle:
    uses: aerospike/shared-workflows/.github/workflows/reusable_promote-release-bundle.yaml@<sha> # version
    with:
      jf-project: database
      jf-bundle-name: database-release
      version: ${{ github.ref_name }}
      new-environment: STAGE
```

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
