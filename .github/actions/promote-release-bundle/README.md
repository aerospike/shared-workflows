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
| `docker-repo`   | No       | Stage Docker repository. Required when `latest` or `latest-slim` is true        |
| `tag`           | No       | Mutable Docker tag to point at, for example `3.3.2`. Required with those inputs |
| `image-name`    | No       | Image name for `latest` and `latest-slim`. Required when either input is true   |
| `latest`        | No       | Apply the `latest` tag after promotion. Optional, off by default                |
| `latest-slim`   | No       | Apply the `latest-slim` tag after promotion. Optional, off by default           |

## Image tags

`jf release-bundle-promote` copies the image tags recorded in the bundle: the immutable tag (`{version}_{YYYYMMDD}T{HHMMSS}Z`), the mutable version (that timestamp stripped), and any other explicit tag the build recorded.

Digest references (`sha256:` and `sha256__`) are not tags. Promotion skips them.

`latest` and `latest-slim` are optional inputs, and both are off by default. When one is true, this action points that exact name at `tag` in `docker-repo`. Otherwise it skips that step.

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
