# Delete Release Bundle

Check for and delete an existing JFrog release bundle version. Safe to call when no bundle exists (outputs `existed=false` and skips deletion).

Note that release bundles can only be deleted from DEV.
This is to make sure that beyond DEV every bundle has unique version and SHA.

Refuses deletion when the bundle version has **completed promotions beyond DEV** (TEST, STAGE, PREVIEW, INTERNAL, or PROD). A promotion-record check runs immediately before delete when a bundle exists.

## Prerequisites

JFrog CLI must be configured before calling this action (via `setup-jfrog-cli`).

## Inputs

| Input         | Required | Description                      |
| ------------- | -------- | -------------------------------- |
| `bundle-name` | Yes      | Release bundle name              |
| `version`     | Yes      | Release bundle version to delete |
| `jf-project`  | Yes      | JFrog project key                |

## Outputs

| Output    | Description                                                      |
| --------- | ---------------------------------------------------------------- |
| `existed` | Whether a matching bundle was found and deleted (`true`/`false`) |

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
  - uses: aerospike/shared-workflows/.github/actions/delete-release-bundle@v3
    with:
      bundle-name: my-release
      version: 1.2.3
      jf-project: my-project
```
