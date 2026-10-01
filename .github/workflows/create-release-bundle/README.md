# Create Release Bundle Workflow

Create JFrog release bundles from a configurable list of build names.

## Overview

This workflow creates JFrog release bundles by bundling one or more builds into a single distributable package.

## Inputs

| Input                              | Description                                                                                                                                                                                                                    | Required | Default                         |
| ---------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | -------- | ------------------------------- |
| `jf-project`                       | JFrog Artifactory project name                                                                                                                                                                                                 | Yes      | -                               |
| `jf-build-names`                   | Comma-separated list of `build-name:build-number` pairs to include. The build number is the JFrog build-info number the deploy job published, not the release version. See [Build names and numbers](#build-names-and-numbers) | Yes      | -                               |
| `jf-bundle-name`                   | Name for the release bundle                                                                                                                                                                                                    | Yes      | -                               |
| `version`                          | Version of the release bundle                                                                                                                                                                                                  | Yes      | -                               |
| `jf-url`                           | JFrog Artifactory URL                                                                                                                                                                                                          | No       | `https://artifact.aerospike.io` |
| `oidc-provider-name`               | OIDC provider name for authentication                                                                                                                                                                                          | No       | `gh-aerospike`                  |
| `oidc-audience`                    | OIDC audience for authentication                                                                                                                                                                                               | No       | `aerospike`                     |
| `runs-on`                          | The runner to use for the build                                                                                                                                                                                                | No       | `ubuntu-22.04`                  |
| `gh-checkout-path`                 | Directory to checkout the shared-workflows repository into                                                                                                                                                                     | No       | `shared-workflows`              |
| `gh-workflows-ref`                 | Git ref for shared-workflows (**should match `uses:`**)                                                                                                                                                                        | Yes      | -                               |
| `dry-run`                          | Whether to run in dry-run mode                                                                                                                                                                                                 | No       | `false`                         |
| `bundle-metadata-path`             | Optional path to `.maven-bundle-metadata.json` (e.g. detect-artifacts `bundle-metadata-path`). Applied as bundle properties after create.                                                                                      | No       | _(empty)_                       |
| `gh-bundle-metadata-artifact-name` | When set, downloads this GitHub artifact and uses the contained `.maven-bundle-metadata.json` (e.g. `reusable_deploy-artifacts` output `bundle-metadata-artifact-name`). Overrides `bundle-metadata-path` when both are set.   | No       | _(empty)_                       |

## Example Usage

**Note**: The example below shows the pattern for external consumers using tagged versions. Internal workflows in this repository use relative paths (e.g., `uses: ./.github/workflows/reusable_create-release-bundle.yaml`) for development and testing.

### Bundle the output of a CI run

```yaml
name: Release
on:
  push:
    tags: ["v*"]

jobs:
  artifacts:
    uses: aerospike/shared-workflows/.github/workflows/reusable_artifacts-cicd.yaml@<sha> # vX.Y.Z
    with:
      jf-project: database
      jf-build-name: database-packages
      # ...

  image:
    uses: aerospike/shared-workflows/.github/workflows/reusable_docker-build-deploy.yaml@<sha> # vX.Y.Z
    with:
      jf-project: database
      jf-build-name: database-image
      # ...

  create-release-bundle:
    needs: [artifacts, image]
    uses: aerospike/shared-workflows/.github/workflows/reusable_create-release-bundle.yaml@<sha> # vX.Y.Z
    with:
      jf-project: database
      jf-build-names: >-
        ${{ needs.artifacts.outputs.jf-build-name }}:${{ needs.artifacts.outputs.jf-build-id }},${{ needs.image.outputs.jf-build-name }}:${{ needs.image.outputs.jf-build-id }}
      jf-bundle-name: database-release
      version: ${{ github.ref_name }}
      gh-workflows-ref: <sha> # Should match the ref in your 'uses:' line
```

### Build names and numbers

Each pair in `jf-build-names` names a JFrog build-info record: the build name and the build number the deploy job published it under. JFrog returns `Build not found` when the number does not match a published record, which is what happens when the release version is passed instead.

| Deploy workflow                     | Build number             | Outputs                        |
| ----------------------------------- | ------------------------ | ------------------------------ |
| `reusable_artifacts-cicd.yaml`      | `{run_id}-{run_attempt}` | `jf-build-name`, `jf-build-id` |
| `reusable_deploy-artifacts.yaml`    | the `jf-build-id` input  | `jf-build-id`                  |
| `reusable_docker-build-deploy.yaml` | `github.run_number`      | `jf-build-name`, `jf-build-id` |

Use the outputs rather than rebuilding the number from `github` context.

## Required: gh-workflows-ref

The `gh-workflows-ref` input is **required** and must match the version in your `uses:` line. See [Why gh-workflows-ref is required](../docs/why-gh-workflows-ref.md) for details.

## Permissions

Callers grant:

```yaml
permissions:
  contents: read
  id-token: write
```

## Prerequisites

- JFrog Artifactory instance with OIDC authentication configured
- GitHub Actions with OIDC token access to Artifactory
- Existing builds in JFrog Artifactory that will be included in the bundle

## Testing

Run the basic test suite:

```bash
.github/workflows/create-release-bundle/test-entrypoint.sh
```
