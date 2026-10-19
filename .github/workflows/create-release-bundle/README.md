# Create Release Bundle Workflow

`reusable_create-release-bundle.yaml` creates a JFrog release bundle from one or more builds.

## Inputs

| Input                              | Description                                                                                                                                                           | Required | Default                         |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | ------------------------------- |
| `gh-workflows-ref`                 | shared-workflows ref. Must match the ref in your `uses:` line, see [Why gh-workflows-ref is required](../docs/why-gh-workflows-ref.md)                                | Yes      | -                               |
| `jf-build-names`                   | Comma-separated `build-name:build-number` pairs. See [Build names and numbers](#build-names-and-numbers)                                                              | Yes      | -                               |
| `jf-bundle-name`                   | Release bundle name                                                                                                                                                   | Yes      | -                               |
| `jf-project`                       | JFrog project key                                                                                                                                                     | Yes      | -                               |
| `version`                          | Release version                                                                                                                                                       | Yes      | -                               |
| `bundle-metadata-path`             | Path to `.maven-bundle-metadata.json` (e.g. the detect-artifacts output `bundle-metadata-path`). Applied as bundle properties after create                            | No       | _(empty)_                       |
| `dry-run`                          | Print the JFrog commands without running them                                                                                                                         | No       | `false`                         |
| `gh-bundle-metadata-artifact-name` | GitHub artifact holding `.maven-bundle-metadata.json` (e.g. the `reusable_deploy-artifacts` output `bundle-metadata-artifact-name`). Overrides `bundle-metadata-path` | No       | _(empty)_                       |
| `gh-checkout-path`                 | Directory to check out shared-workflows into                                                                                                                          | No       | `shared-workflows`              |
| `jf-bundle-revision`               | Appended to `version` to form the bundle version. See [Bundle revisions](#bundle-revisions)                                                                           | No       | _(empty)_                       |
| `jf-url`                           | JFrog URL                                                                                                                                                             | No       | `https://artifact.aerospike.io` |
| `oidc-audience`                    | OIDC audience                                                                                                                                                         | No       | `aerospike`                     |
| `oidc-provider-name`               | OIDC provider name                                                                                                                                                    | No       | `gh-aerospike`                  |
| `runs-on`                          | Runner label for the job                                                                                                                                              | No       | `ubuntu-22.04`                  |

## Outputs

| Output           | Description                                                                                         |
| ---------------- | --------------------------------------------------------------------------------------------------- |
| `bundle-version` | The bundle version created (in dry-run, the one that would be created). Promote this, not `version` |

## Example

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
      gh-workflows-ref: <sha>
      jf-project: database
      jf-build-names: >-
        ${{ needs.artifacts.outputs.jf-build-name }}:${{ needs.artifacts.outputs.jf-build-id }},${{ needs.image.outputs.jf-build-name }}:${{ needs.image.outputs.jf-build-id }}
      jf-bundle-name: database-release
      version: ${{ github.ref_name }}
```

## Build names and numbers

Each pair in `jf-build-names` is a build name and the build number the deploy job published it under. Passing the release version instead gets `Build not found`. Take both from the deploy job's outputs:

| Deploy workflow                     | Build number             | Outputs                        |
| ----------------------------------- | ------------------------ | ------------------------------ |
| `reusable_artifacts-cicd.yaml`      | `{run_id}-{run_attempt}` | `jf-build-name`, `jf-build-id` |
| `reusable_deploy-artifacts.yaml`    | the `jf-build-id` input  | `jf-build-id`                  |
| `reusable_docker-build-deploy.yaml` | `github.run_number`      | `jf-build-name`, `jf-build-id` |

## Permissions

Callers grant:

```yaml
permissions:
  contents: read
  id-token: write
```

## Prerequisites

- An OIDC mapping that lets the calling repository create release bundles in the JFrog project.
- The builds in `jf-build-names` exist in JFrog.

## Bundle revisions

A release version is not unique per build, so a second bundle for the same release collides with the
first. `jf-bundle-revision` gives each build its own bundle version, and the artifacts keep `version`:

```yaml
with:
  version: 1.2.3
  jf-bundle-revision: auto # bundle version 1.2.3-<run_id>-<run_attempt>
```

Promote the `bundle-version` output, not `version`.

The revision does not change artifact paths. Once an earlier revision is promoted to DEV, its paths are
locked and a rebuild's deploy fails on them. To clear them with `delete-release-bundle`, pass that
revision's bundle version.

Unset, the bundle version is `version` and the run logs a warning: a future release will default to
`auto`.

## Testing

```bash
.github/workflows/create-release-bundle/test-entrypoint.sh
bats .github/workflows/create-release-bundle/tests/bats/
```
