# Sign Windows Artifacts Workflow

This reusable workflow signs **Windows Authenticode** artifacts (`.exe`, `.msi`, `.msix`) using **SSL.com eSigner CodeSignTool**, mirroring the layout of [`reusable_sign-mac-artifacts.yaml`](../reusable_sign-mac-artifacts.yaml): download artifact tree, sign selected files, re-upload with `overwrite: true`.

Apple certificates and identities from Mac signing **do not apply** here. Windows signing uses **OV**-scoped workflow secrets (`es_ov_username`, `es_ov_password`, `es_ov_credential_id`, `es_ov_totp_secret`), typically mapped from repository secrets **`ES_OV_USERNAME`**, **`ES_OV_PASSWORD`**, **`ES_OV_CREDENTIAL_ID`**, and **`ES_OV_TOTP_SECRET`**. NuGet signing in [`reusable_sign-artifacts.yaml`](../reusable_sign-artifacts.yaml) still uses the separate `es-username` / `es-password` / `credential_id` / `es-totp_secret` inputs (often backed by different repo secret names); you can map both sets from the same SSL.com account if you choose.

The default runner is **`windows-2025`** (Git Bash) so **CodeSignTool.bat** from the official Windows bundle is used. If CodeSignTool rejects a specific MSIX payload, SSL.com also documents **eSigner CKA + Microsoft SignTool** as an alternative.

When this job runs **before** [`reusable_sign-artifacts.yaml`](../reusable_sign-artifacts.yaml) in [`reusable_artifacts-cicd.yaml`](../reusable_artifacts-cicd.yaml), the **Sign Artifacts** step **does not** GPG-sign `.exe`, `.msi`, or `.msix` (they are moved aside and merged back, same idea as `.nupkg` vs SSL.com-only).

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

| Name                  | Required     | Description                   |
| --------------------- | ------------ | ----------------------------- |
| `es_ov_username`      | When signing | SSL.com account username      |
| `es_ov_password`      | When signing | SSL.com account password      |
| `es_ov_credential_id` | When signing | eSigner credential ID         |
| `es_ov_totp_secret`   | When signing | TOTP secret for automated OTP |

The signing step sets environment variables **`ES_OV_USERNAME`**, **`ES_OV_PASSWORD`**, **`ES_OV_CREDENTIAL_ID`**, and **`ES_OV_TOTP_SECRET`** for [`entrypoint.sh`](./entrypoint.sh).

When `dry-run: true`, these secrets may be omitted.

**Windows:** SSL.com’s `CodeSignTool.bat` runs the bundled JRE via paths relative to the **extracted bundle root** only when `CODE_SIGN_TOOL_PATH` is set; otherwise it uses `.\jdk-*`, which resolves against the **process cwd** (often the GitHub workspace, where there is no `jdk-*`). This reusable workflow sets `CODE_SIGN_TOOL_PATH` after unzip. If you call [`entrypoint.sh`](./entrypoint.sh) yourself on Windows, export `CODE_SIGN_TOOL_PATH` to the absolute Windows path of that bundle root (parent of `CodeSignTool.bat`).

**`java.io.IOException: DOS header signature not found`:** CodeSignTool is parsing the file as a **PE executable** (`.exe`). The first two bytes must be **`MZ`** (`0x4D 0x5A`). Placeholder or zero-filled files, or non-PE content renamed to `.exe`, will fail. Build a real Windows binary (e.g. MSVC or MinGW) or use a valid test artifact.

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
      es_ov_username: ${{ secrets.ES_OV_USERNAME }}
      es_ov_password: ${{ secrets.ES_OV_PASSWORD }}
      es_ov_credential_id: ${{ secrets.ES_OV_CREDENTIAL_ID }}
      es_ov_totp_secret: ${{ secrets.ES_OV_TOTP_SECRET }}
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
