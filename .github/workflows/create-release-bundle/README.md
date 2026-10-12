# Create Release Bundle Workflow

`reusable_create-release-bundle.yaml` creates a JFrog release bundle from one or more builds.

## Inputs

| Input                              | Description                                                                                                                                                           | Required | Default                         |
| ---------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------- | ------------------------------- |
| `gh-workflows-ref`                 | shared-workflows ref. Must match the ref in your `uses:` line, see [Why gh-workflows-ref is required](../docs/why-gh-workflows-ref.md)                                | Yes      | -                               |
| `jf-build-names`                   | Comma-separated `build-name:version` pairs, e.g. `app-build:1.2.3,client-build:2.1.0`                                                                                 | Yes      | -                               |
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
| `runs-on`                          | Runner                                                                                                                                                                | No       | `ubuntu-22.04`                  |

## Outputs

| Output           | Description                                                                                         |
| ---------------- | --------------------------------------------------------------------------------------------------- |
| `bundle-version` | The bundle version created (in dry-run, the one that would be created). Promote this, not `version` |

## Example

```yaml
name: Create Release Bundle
on:
  workflow_dispatch:
  push:
    tags: ["v*"]

jobs:
  create-release-bundle:
    uses: aerospike/shared-workflows/.github/workflows/reusable_create-release-bundle.yaml@v3.2.0
    with:
      gh-workflows-ref: v3.2.0
      jf-project: database
      jf-build-names: "database-build:1.2.3,client-build:2.1.0"
      jf-bundle-name: database-release
      version: ${{ github.ref_name }}
```

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
