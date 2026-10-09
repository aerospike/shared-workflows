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

## Floating tags

After `jf release-bundle-promote` succeeds, this action recomputes Docker floating tags in the target stage repository. A source-to-target mapping in the promotion result is used as written. When the result has no mapping, the Docker and OCI repositories JFrog assigned to that environment are used. Repository names are not rewritten.

For each image named by the bundle property `docker.floating_tags`:

- A floating tag is recomputed only when the bundle names it. `3.3.2` does not imply `latest`, and `3.3.2-slim` does not imply `latest-slim`.
- `latest` points at the highest dotted version tag with no variant suffix.
- `latest-<suffix>` (for example `latest-slim`) points at the highest version tag that ends in that suffix, compared after stripping it.
- Digest tags and immutable tags (`_<YYYYMMDD>T<HHMMSS>Z`) are ignored. A suffixed tag never becomes `latest`.
- If the repository has no candidate version tag, the floating tag is removed.

An older release promoted into a repository that already has a newer version tag leaves `latest` on the newer tag.

There is no un-promote workflow. When a release leaves a stage, run [recompute-docker-floating-tags](../recompute-docker-floating-tags/README.md) against that stage's repository so `latest` does not stay on the release that left. That action does not delete the bundle. `delete-release-bundle` still refuses bundles promoted beyond DEV. If retag fails after a promotion that already succeeded, rerun that action instead of promoting again.

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
