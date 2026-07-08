# Delete Release Bundle

Check for and delete an existing JFrog release bundle version. Safe to call when no bundle exists (outputs `existed=false` and skips deletion).

Refuses deletion when the bundle version has **completed promotions beyond DEV** (TEST, STAGE, PREVIEW, INTERNAL, or PROD). Two promotion-record checks run when a bundle exists: once before showing bundle details, and again immediately before delete (defense in depth against promotion races).

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
