# Sign Artifacts Workflow

This is a reusable GitHub Actions workflow that signs binary artifacts using GPG. It supports `.deb`, `.rpm`, and any other file type passed via a glob pattern. It produces:

- GPG detached signature (`.asc`) for any file
- Native signing for `.deb` and `.rpm` using `dpkg-sig` and `rpm --addsign`

---

## Inputs

| Name                    | Type     | Required | Description                                                                                               |
| ----------------------- | -------- | -------- | --------------------------------------------------------------------------------------------------------- |
| `gh-unsigned-artifacts` | `string` | No       | Previously uploaded artifacts to sign. Default: `unsigned-artifacts*`                                     |
| `gh-artifact-name`      | `string` | No       | Name for the uploaded artifacts. Default: `signed-artifacts`                                              |
| `gh-retention-days`     | `number` | No       | Number of days to retain the signed artifacts. Default: `1`                                               |
| `jf-url`                | `string` | No       | JFrog Artifactory URL. Default: `https://artifact.aerospike.io`                                           |
| `oidc-provider-name`    | `string` | No       | OIDC provider name. Default: `gh-aerospike`                                                               |
| `oidc-audience`         | `string` | No       | OIDC audience. Default: `aerospike`                                                                       |
| `gh-checkout-path`      | `string` | No       | Directory to checkout the shared-workflows repository into. Default: `shared-workflows`                   |
| `gh-workflows-ref`      | `string` | No       | Git reference to checkout shared-workflows repository (tag, branch, or SHA). Default: `bugfix/rpm-builds` |
| `runs-on`               | `string` | No       | The runner to use for the build. Default: `ubuntu-22.04`                                                  |

## Secrets

| Name              | Description                     |
| ----------------- | ------------------------------- |
| `gpg-private-key` | GPG private key for signing     |
| `gpg-public-key`  | GPG public key for verification |
| `gpg-key-pass`    | Passphrase for the GPG key      |

---

## Example Usage

From another workflow:

```yaml
jobs:
  sign:
    uses: aerospike/shared-workflows/.github/workflows/reusable_sign-artifacts.yaml@bugfix/rpm-builds
    with:
      gh-unsigned-artifacts: test-fixtures
      gh-artifact-name: signed-artifacts # optional, defaults to signed-artifacts
      gh-retention-days: 7 # optional, defaults to 1
      gh-workflows-ref: bugfix/rpm-builds # Use specific shared-workflows version
    secrets:
      gpg-private-key: ${{ secrets.GPG_SECRET_KEY }}
      gpg-public-key: ${{ secrets.GPG_PUBLIC_KEY }}
      gpg-key-pass: ${{ secrets.GPG_PASS }}
```

## Output

The workflow uploads the signed artifacts as a GitHub Actions artifact with the specified retention period.
