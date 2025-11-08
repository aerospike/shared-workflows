# Sign Artifacts Workflow

This is a reusable GitHub Actions workflow that signs binary artifacts using GPG. It supports `.deb`, `.rpm`, `.nupkg` (NuGet via SSL.com), and any other file type passed via a glob pattern. It produces:

- GPG detached signature (`.asc`) for any file
- Native signing for `.deb` and `.rpm` using `dpkg-sig` and `rpm --addsign`

---

## Inputs

| Name                    | Type     | Required | Description                                                                                    |
| ----------------------- | -------- | -------- | ---------------------------------------------------------------------------------------------- |
| `gh-unsigned-artifacts` | `string` | No       | Previously uploaded artifacts to sign. Default: `build-artifacts`                              |
| `gh-artifact-name`      | `string` | No       | Name for the uploaded signed artifacts. Default: `signed-artifacts`                            |
| `gh-retention-days`     | `number` | No       | Number of days to retain the signed artifacts. Default: `1`                                    |
| `gh-checkout-path`      | `string` | No       | Directory to checkout the shared-workflows repository into. Default: `shared-workflows`        |
| `gh-workflows-ref`      | `string` | No       | Git reference to checkout shared-workflows repository (tag, branch, or SHA). Default: `v2.0.2` |
| `runs-on`               | `string` | No       | The runner to use. Default: `ubuntu-22.04`                                                     |
| `nuget-environment`     | `string` | No       | SSL.com environment name for NuGet signing. Default: `PROD`                                    |

## Secrets

| Name              | Required | Description                              |
| ----------------- | -------- | ---------------------------------------- |
| `gpg-private-key` | Yes      | GPG private key for signing              |
| `gpg-public-key`  | Yes      | GPG public key for verification          |
| `gpg-key-pass`    | Yes      | Passphrase for the GPG key               |
| `es-username`     | Cond.    | SSL.com account username (NuGet signing) |
| `es-password`     | Cond.    | SSL.com account password (NuGet signing) |
| `credential_id`   | Cond.    | SSL.com credential ID (NuGet signing)    |
| `es-totp_secret`  | Cond.    | SSL.com TOTP secret (NuGet signing)      |

Notes:

- NuGet signing runs only if `.nupkg` files are present in the unsigned artifacts.
- If `.nupkg` files are found, all four SSL.com secrets above must be provided or the workflow fails.

---

## Example Usage

From another workflow:

```yaml
jobs:
  sign:
    uses: aerospike/shared-workflows/.github/workflows/reusable_sign-artifacts.yaml@v2.0.2
    with:
      gh-unsigned-artifacts: test-fixtures
      gh-artifact-name: signed-artifacts # optional, defaults to signed-artifacts
      gh-retention-days: 7 # optional, defaults to 1
      gh-workflows-ref: v2.0.2 # Use specific shared-workflows version
    secrets:
      gpg-private-key: ${{ secrets.GPG_SECRET_KEY }}
      gpg-public-key: ${{ secrets.GPG_PUBLIC_KEY }}
      gpg-key-pass: ${{ secrets.GPG_PASS }}
      # Optional - required only if NuGet packages are present
      es-username: ${{ secrets.ES_USERNAME }}
      es-password: ${{ secrets.ES_PASSWORD }}
      credential_id: ${{ secrets.CREDENTIAL_ID }}
      es-totp_secret: ${{ secrets.ES_TOTP_SECRET }}
```

## Outputs

| Name               | Description                                          |
| ------------------ | ---------------------------------------------------- |
| `gh-artifact-name` | The name of the uploaded signed artifacts (artifact) |

Artifacts layout:

- Signed outputs are uploaded under the artifact name provided by `gh-artifact-name`.
