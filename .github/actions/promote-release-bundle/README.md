# Promote Release Bundle

Promote a JFrog release bundle to a target promotion stage (DEV, TEST, STAGE, PROD, etc.).

## Prerequisites

JFrog CLI must be configured before calling this action (via `setup-jfrog-cli`).

## Inputs

| Input           | Required | Description                                                                     |
| --------------- | -------- | ------------------------------------------------------------------------------- |
| `bundle-name`   | Yes      | Release bundle name                                                             |
| `version`       | Yes      | Release bundle version to promote                                               |
| `environment`   | Yes      | Target promotion stage (DEV, TEST, STAGE, PROD, etc.)                           |
| `jf-project`    | Yes      | JFrog project key                                                               |
| `include-repos` | No       | Semicolon-separated list of target repos to include in promotion (limits scope) |
| `exclude-repos` | No       | Semicolon-separated list of target repos to exclude from promotion              |

## Image tags

`jf release-bundle-promote` copies the image tags recorded in the bundle: the immutable tag (`{version}_{YYYYMMDD}T{HHMMSS}Z`), the mutable version (that timestamp stripped), and any other explicit tag the build recorded.

Digest references (`sha256:` and `sha256__`) are not tags. Promotion skips them.

After the copy, this action points `latest` or `latest-slim` at the mutable Docker tag when both of these are true:

1. The build recorded that token because `versions-override` named it. The image name and the mutable tag come from the release-bundle record.
2. The destination is a stage repository (a Docker or OCI local repository for this environment whose key contains `-stage-`) or `environment` is `PROD`.

DEV and TEST do not move those tags. A version tag does not imply `latest`.

## Example Usage

```yaml
steps:
  - uses: step-security/setup-jfrog-cli@v4
    env:
      JF_URL: https://artifact.aerospike.io
      JF_PROJECT: my-project
    with:
      oidc-provider-name: gh-aerospike
      oidc-audience: aerospike
  - uses: aerospike/shared-workflows/.github/actions/promote-release-bundle@v3
    with:
      bundle-name: my-release
      version: 1.2.3
      environment: DEV
      jf-project: my-project
```
