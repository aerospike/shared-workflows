# Sign Artifacts Workflow

> **Note:** This workflow is used internally by [`reusable_artifacts-cicd.yaml`](../artifacts-cicd/README.md). Most consumers should use the orchestrator rather than calling this directly.

This is a reusable GitHub Actions workflow that signs binary artifacts using GPG. It supports `.deb`, `.rpm`, `.nupkg` (NuGet via SSL.com), Helm charts, and other file types passed via a glob pattern. It produces:

- GPG detached signature (`.asc`) for generic files that pass through the GPG stage (e.g. `.jar`, Gradle `.module` metadata, `.zip`, plain tarballs)
- Native signing for `.deb` and `.rpm` using `dpkg-sig` and `rpm --addsign`
- Helm chart provenance (`.prov`) for packaged charts (`.tgz`/`.tar.gz` containing a `Chart.yaml`): a GPG-clearsigned message containing the chart's `Chart.yaml` plus a sha256 of the tarball, the same native format `helm package --sign` produces. The chart receives a `.prov` rather than a detached `.asc`, and consumers verify with `helm verify` or `helm install --verify`.

**Not** GPG-signed here (same pattern as NuGet, which is moved out before GPG):

- **`.nupkg`** — handled only by SSL.com eSigner in this workflow
- **`.exe`, `.msi`, `.msix`** — reserved for **Windows Authenticode** (e.g. `reusable_sign-win-artifacts` in the orchestrator), which uses SSL.com secrets **`ES_OV_USERNAME`**, **`ES_OV_PASSWORD`**, **`ES_OV_CREDENTIAL_ID`**, and **`ES_OV_TOTP_SECRET`** (see [`sign-win-artifacts/README.md`](../sign-win-artifacts/README.md)). They are moved aside before GPG and copied back into the signed artifact tree afterward so deploy still sees the same paths. Optional existing `*.asc` sidecars next to those files move with them.

---

## Inputs

| Name                    | Type     | Required | Description                                                                             |
| ----------------------- | -------- | -------- | --------------------------------------------------------------------------------------- |
| `gh-unsigned-artifacts` | `string` | No       | Previously uploaded artifacts to sign. Default: `build-artifacts`                       |
| `gh-artifact-name`      | `string` | No       | Name for the uploaded signed artifacts. Default: `signed-artifacts`                     |
| `gh-retention-days`     | `number` | No       | Number of days to retain the signed artifacts. Default: `1`                             |
| `gh-checkout-path`      | `string` | No       | Directory to checkout the shared-workflows repository into. Default: `shared-workflows` |
| `gh-workflows-ref`      | `string` | Yes      | Git ref for shared-workflows (**should match your `uses:` version**)                    |
| `runs-on`               | `string` | No       | The runner to use. Default: `ubuntu-22.04`                                              |
| `nuget-environment`     | `string` | No       | SSL.com environment name for NuGet signing. Default: `PROD`                             |

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
- GPG setup and signing are skipped automatically when no GPG-signable files remain after NuGet and Windows Authenticode isolation (e.g. a NuGet-only or Windows-only build). The job still uploads the signed NuGet/Windows outputs.
- GPG signing is also skipped when GPG secrets are unavailable (e.g. Dependabot `push` workflows). Unsigned artifacts are staged into the signed artifact tree so the job can still succeed and downstream steps receive the build outputs.
- **macOS `.pkg` / `.dmg`** are not isolated by this workflow; they still receive GPG detached signatures if present under `unsigned-artifacts`. Use the orchestrator’s `sign-mac` job for Apple signing before this job when you need Apple-only treatment.

---

## Example Usage

**Note**: The example below shows the pattern for external consumers using tagged versions. Internal workflows in this repository use relative paths (e.g., `uses: ./.github/workflows/reusable_sign-artifacts.yaml`) for development and testing.

From another workflow:

```yaml
jobs:
  sign:
    uses: aerospike/shared-workflows/.github/workflows/reusable_sign-artifacts.yaml@v3.2.0
    with:
      gh-unsigned-artifacts: test-fixtures
      gh-artifact-name: signed-artifacts # optional, defaults to signed-artifacts
      gh-retention-days: 7 # optional, defaults to 1
      gh-workflows-ref: v3.2.0 # Should match the version in your 'uses:' line
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

## Required: gh-workflows-ref

The `gh-workflows-ref` input is **required** and must match the version in your `uses:` line. See [Why gh-workflows-ref is required](../docs/why-gh-workflows-ref.md) for details.

## Outputs

| Name               | Description                                          |
| ------------------ | ---------------------------------------------------- |
| `gh-artifact-name` | The name of the uploaded signed artifacts (artifact) |

Artifacts layout:

- Signed outputs are uploaded under the artifact name provided by `gh-artifact-name`.
