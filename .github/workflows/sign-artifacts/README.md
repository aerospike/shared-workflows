# Sign Artifacts Workflow

This is a reusable GitHub Actions workflow that signs binary artifacts using GPG. It supports `.deb`, `.rpm`, and any other file type passed via a glob pattern. It produces:

- GPG detached signature (`.asc`) for any file
- SHA256 checksums for both the file and signature (`.sha256`, `.asc.sha256`)
- Native signing for `.deb` and `.rpm` using `dpkg-sig` and `rpm --addsign`

---

## Inputs

| Name                             | Type     | Required | Description                                                                             |
| -------------------------------- | -------- | -------- | --------------------------------------------------------------------------------------- |
| `artifact-glob`                  | `string` | Yes      | Glob pattern to match artifacts for signing. Example: `dist/**/*.{deb,rpm}`             |
| `artifact-name`                  | `string` | No       | Name for the uploaded artifacts. Default: `signed-artifacts`                            |
| `retention-days`                 | `number` | No       | Number of days to retain the signed artifacts. Default: `1`                             |
| `artifactory-url`                | `string` | No       | JFrog Artifactory URL. Default: `https://aerospike.jfrog.io`                            |
| `artifactory-oidc-provider-name` | `string` | No       | OIDC provider name. Default: `gh-aerospike`                                             |
| `artifactory-oidc-audience`      | `string` | No       | OIDC audience. Default: `aerospike`                                                     |
| `checkout-path`                  | `string` | No       | Directory to checkout the shared-workflows repository into. Default: `shared-workflows` |
| `runs-on`                        | `string` | No       | The runner to use for the build. Default: `ubuntu-22.04`                                |

## Secrets

| Name              | Required | Description                     |
| ----------------- | -------- | ------------------------------- |
| `gpg-private-key` | ✅       | GPG private key for signing     |
| `gpg-public-key`  | ✅       | GPG public key for verification |
| `gpg-key-pass`    | ✅       | Passphrase for the GPG key      |

---

## Example Usage

From another workflow:

```yaml
jobs:
  sign:
    uses: aerospike/shared-workflows/.github/workflows/reusable_sign-artifacts.yaml@CURRENTGITSHA # vn.n.n
    with:
      artifact-glob: dist/**/*.{deb,rpm}
      # artifact-name: signed-artifacts  # optional, defaults to signed-artifacts
      # retention-days: 7               # optional, defaults to 7
      # dry-run: false                  # optional, for future compatibility
    secrets:
      gpg-private-key: ${{ secrets.GPG_SECRET_KEY }}
      gpg-public-key: ${{ secrets.GPG_PUBLIC_KEY }}
      gpg-key-pass: ${{ secrets.GPG_PASS }}
```

## Output

The workflow uploads the signed artifacts as a GitHub Actions artifact with the specified retention period.
