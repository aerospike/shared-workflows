# Sign Windows Artifacts Workflow

This reusable workflow signs **Windows Authenticode** artifacts (`.exe`, `.msi`, `.msix`) using **SSL.com eSigner CodeSignTool**, mirroring the layout of [`reusable_sign-mac-artifacts.yaml`](../reusable_sign-mac-artifacts.yaml): download artifact tree, sign selected files, re-upload with `overwrite: true`.

Apple certificates and identities from Mac signing **do not apply** here. Use the **same SSL.com eSigner secrets** as [`reusable_sign-artifacts.yaml`](../reusable_sign-artifacts.yaml) NuGet signing (`es-username`, `es-password`, `credential_id`, `es-totp_secret`) so one account can cover NuGet and Windows binaries.

The default runner is **`windows-2025`** (Git Bash) so **CodeSignTool.bat** from the official Windows bundle is used. If CodeSignTool rejects a specific MSIX payload, SSL.com also documents **eSigner CKA + Microsoft SignTool** as an alternative.

---

## Inputs

| Name                    | Type      | Required | Description                                                                                                                                                         |
| ----------------------- | --------- | -------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `gh-workflows-ref`      | `string`  | Yes      | Git ref for shared-workflows (**must match your `uses:` version**)                                                                                                  |
| `artifact-glob`         | `string`  | No       | Glob for signing scope (default: `**/*`). Use one pattern or **comma-separated** patterns (spaces optional), e.g. `*.exe,*.msi,*.msix`. Full tree is always copied. |
| `codesigntool-version`  | `string`  | No       | CodeSignTool release to install from GitHub (default: `1.3.2`). Ignored when `dry-run: true`.                                                                       |
| `dry-run`               | `boolean` | No       | Skip CodeSignTool and eSigner secret requirements. Default: `false`                                                                                                 |
| `gh-checkout-path`      | `string`  | No       | Checkout path for shared-workflows. Default: `shared-workflows`                                                                                                     |
| `gh-retention-days`     | `number`  | No       | Artifact retention days. Default: `1`                                                                                                                               |
| `gh-unsigned-artifacts` | `string`  | No       | GitHub artifact name to download and overwrite. Default: `build-artifacts`                                                                                          |
| `runs-on`               | `string`  | No       | Runner label. Default: `windows-2025` (Git Bash; Linux values still install `CodeSignTool.sh`)                                                                      |
| `signing-identity`      | `string`  | No       | Optional MSI display name (CodeSignTool `-program_name`). Often your product name.                                                                                  |

## Secrets

| Name             | Required     | Description                   |
| ---------------- | ------------ | ----------------------------- |
| `es-username`    | When signing | SSL.com account username      |
| `es-password`    | When signing | SSL.com account password      |
| `credential_id`  | When signing | eSigner credential ID         |
| `es-totp_secret` | When signing | TOTP secret for automated OTP |

When `dry-run: true`, these secrets may be omitted.

---

## Example Usage

### Composable (direct call)

```yaml
jobs:
  sign-win:
    uses: aerospike/shared-workflows/.github/workflows/reusable_sign-win-artifacts.yaml@v4.0.0
    with:
      gh-unsigned-artifacts: build-artifacts
      gh-workflows-ref: v4.0.0
      signing-identity: "My Product Installer"
      artifact-glob: "*.exe,*.msi,*.msix"
    secrets:
      es-username: ${{ secrets.ES_USERNAME }}
      es-password: ${{ secrets.ES_PASSWORD }}
      credential_id: ${{ secrets.CREDENTIAL_ID }}
      es-totp_secret: ${{ secrets.ES_TOTP_SECRET }}
```

## Required: gh-workflows-ref

Same requirement as other reusable workflows; see [Why gh-workflows-ref is required](../docs/why-gh-workflows-ref.md).

## Outputs

| Name               | Description                                       |
| ------------------ | ------------------------------------------------- |
| `gh-artifact-name` | The name of the uploaded artifact (same as input) |

## Testing

- **Bats tests** (mocked CodeSignTool): `bats .github/workflows/sign-win-artifacts/tests/bats/`
- **CI dry-run**: `test_sign-win-artifacts-workflow.yaml` runs on PRs touching `reusable_sign-win-artifacts.yaml` or `sign-win-artifacts/**`
- **Manual smoke test**: `test_sign-win-artifacts-smoke.yaml` (`workflow_dispatch`) for end-to-end signing with real eSigner secrets; optional repo variable `WIN_SIGNING_PROGRAM_NAME` for `signing-identity`
