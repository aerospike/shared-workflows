# Delete Release Bundle

Check for and delete an existing JFrog release bundle version. Safe to call when no bundle exists (outputs `existed=false` and skips deletion).

Note that release bundles can only be deleted from DEV.
This is to make sure that beyond DEV every bundle has unique version and SHA.

Refuses deletion when the bundle version is **promoted, or being promoted, to any stage other than DEV**. A promotion that failed does not count. A promotion-record check runs immediately before delete when a bundle exists. If the promotion records cannot be read, the check refuses the delete.

## Prerequisites

JFrog CLI must be configured before calling this action (via `setup-jfrog-cli`), with an access token: the check reads the promotion records with that token and `curl`.

The check sources `.github/workflows/lib/jfrog-lifecycle.sh` from the same checkout. A caller that runs this action from a local sparse checkout (`uses: ./.github/actions/delete-release-bundle`) must include `.github/workflows/lib` in it.

## Inputs

| Input         | Required | Description                                                                                                                            |
| ------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `bundle-name` | Yes      | Release bundle name                                                                                                                    |
| `version`     | Yes      | Release bundle version to delete. With a revision this is the bundle version (`1.2.3-<run_id>-<run_attempt>`), not the release version |
| `jf-project`  | Yes      | JFrog project key                                                                                                                      |

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
