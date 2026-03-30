# Promote Release Bundle

Promote a JFrog release bundle to a target environment (DEV, TEST, STAGE, PROD, etc.).

## Prerequisites

JFrog CLI must be configured before calling this action (via `setup-jfrog-cli`).

## Inputs

| Input         | Required | Description                                       |
| ------------- | -------- | ------------------------------------------------- |
| `bundle-name` | Yes      | Release bundle name                               |
| `version`     | Yes      | Release bundle version to promote                 |
| `environment` | Yes      | Target environment (DEV, TEST, STAGE, PROD, etc.) |
| `jf-project`  | Yes      | JFrog project key                                 |

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
