# Delete Release Bundle

Deletes a JFrog release bundle version if it exists. When it does not, the action outputs `existed=false` and deletes nothing.

It refuses to delete a version that is promoted, or being promoted, to any stage other than DEV. A failed promotion does not count. If the promotion records cannot be read, it refuses.

## Prerequisites

- The JFrog CLI is configured with an access token (`setup-jfrog-cli`).
- A local sparse checkout (`uses: ./.github/actions/delete-release-bundle`) must include `.github/workflows/lib`, which the promotion check sources.

## Inputs

| Input         | Required | Description                                                                                        |
| ------------- | -------- | -------------------------------------------------------------------------------------------------- |
| `bundle-name` | Yes      | Release bundle name                                                                                |
| `version`     | Yes      | Bundle version to delete. With a revision, this is `<version>-<revision>`, not the release version |
| `jf-project`  | Yes      | JFrog project key                                                                                  |

## Outputs

| Output    | Description                                                         |
| --------- | ------------------------------------------------------------------- |
| `existed` | Whether the bundle version existed and was deleted (`true`/`false`) |

## Example

```yaml
steps:
  - uses: step-security/setup-jfrog-cli@v4
    env:
      JF_URL: https://artifact.aerospike.io
      JF_PROJECT: my-project
    with:
      oidc-provider-name: gh-aerospike
      oidc-audience: aerospike
  - uses: aerospike/shared-workflows/.github/actions/delete-release-bundle@v3
    with:
      bundle-name: my-release
      version: 1.2.3
      jf-project: my-project
```
