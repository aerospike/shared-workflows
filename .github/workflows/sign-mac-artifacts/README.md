# Sign Mac Artifacts Workflow

> **Note:** This workflow is used internally by [`reusable_artifacts-cicd.yaml`](../artifacts-cicd/README.md) when `sign-mac: true` is set. It can also be called directly for composable pipelines.

This is a reusable GitHub Actions workflow that signs and optionally notarizes macOS artifacts. It supports:

- **Mach-O binaries**: signed with `codesign`
- **.pkg installer packages**: signed with `productsign`, then notarized and stapled
- **.dmg disk images**: signed with `codesign`, then notarized and stapled

Every sign and notarize operation is followed by a verification step. Notarization failures fetch the full Apple log for diagnostics.

The workflow downloads the full artifact tree, signs only the files matching `artifact-glob`, and re-uploads the complete tree with `overwrite: true`. Non-Mac artifacts (deb, rpm, jar, etc.) pass through untouched.

---

## Inputs

| Name                    | Type      | Required | Description                                                                             |
| ----------------------- | --------- | -------- | --------------------------------------------------------------------------------------- |
| `gh-workflows-ref`      | `string`  | Yes      | Git ref for shared-workflows (**should match your `uses:` version**)                    |
| `signing-identity`      | `string`  | Yes      | Apple codesign identity (e.g. `Developer ID Application: Aerospike, Inc. (TEAMID)`)     |
| `artifact-glob`         | `string`  | No       | Glob pattern for files to sign (default: `**/*`). Controls signing scope, not download. |
| `dry-run`               | `boolean` | No       | Run without actual signing or notarization. Default: `false`                            |
| `gh-checkout-path`      | `string`  | No       | Checkout path for shared-workflows. Default: `shared-workflows`                         |
| `gh-retention-days`     | `number`  | No       | Artifact retention days. Default: `1`                                                   |
| `gh-unsigned-artifacts` | `string`  | No       | GitHub artifact name to download and overwrite. Default: `build-artifacts`              |
| `installer-identity`    | `string`  | No       | Apple productsign identity. Required when signing `.pkg` files.                         |
| `notarize`              | `boolean` | No       | Submit to Apple for notarization after signing. Default: `true`                         |
| `runs-on`               | `string`  | No       | macOS runner label. Default: `macos-14`                                                 |

## Secrets

| Name                          | Required | Description                                                             |
| ----------------------------- | -------- | ----------------------------------------------------------------------- |
| `apple-application-cert`      | Yes      | Base64-encoded `.p12` for `codesign` (Developer ID Application)         |
| `apple-id`                    | Cond.    | Apple ID email (required when `notarize: true`)                         |
| `apple-installer-cert`        | Cond.    | Base64-encoded `.p12` for `productsign` (required for `.pkg` signing)   |
| `apple-cert-password`         | No       | Password for `.p12` certificate import (if cert is password-protected)  |
| `apple-notarization-password` | Cond.    | App-specific password for notarization (required when `notarize: true`) |
| `apple-team-id`               | Cond.    | Apple Developer Team ID (required when `notarize: true`)                |

---

## Example Usage

### Composable (direct call)

```yaml
jobs:
  sign-mac:
    uses: aerospike/shared-workflows/.github/workflows/reusable_sign-mac-artifacts.yaml@v4.0.0
    with:
      gh-unsigned-artifacts: build-artifacts
      gh-workflows-ref: v4.0.0
      signing-identity: "Developer ID Application: Aerospike, Inc. (23221RFU77)"
      installer-identity: "Developer ID Installer: Aerospike, Inc. (23221RFU77)"
      artifact-glob: "*.pkg"
    secrets:
      apple-application-cert: ${{ secrets.APPLE_APPLICATION_CERT }}
      apple-id: ${{ secrets.APPLE_ID }}
      apple-installer-cert: ${{ secrets.APPLE_INSTALLER_CERT }}
      apple-cert-password: ${{ secrets.APPLE_CERT_PASSWORD }}
      apple-notarization-password: ${{ secrets.APPLE_NOTARIZATION_PASSWORD }}
      apple-team-id: ${{ secrets.APPLE_TEAM_ID }}
```

### Via orchestrator

```yaml
jobs:
  ci:
    uses: aerospike/shared-workflows/.github/workflows/reusable_artifacts-cicd.yaml@v4.0.0
    with:
      gh-workflows-ref: v4.0.0
      jf-project: my-project
      jf-build-name: my-app
      version: 1.2.3
      gh-artifact-directory: dist
      build-script: make build

      # Mac signing
      sign-mac: true
      mac-signing-identity: "Developer ID Application: Aerospike, Inc. (23221RFU77)"
      mac-installer-identity: "Developer ID Installer: Aerospike, Inc. (23221RFU77)"
      mac-artifact-glob: "*.pkg"
    secrets: inherit
```

## Required: gh-workflows-ref

The `gh-workflows-ref` input is **required** and must match the version in your `uses:` line. See [Why gh-workflows-ref is required](../docs/why-gh-workflows-ref.md) for details.

## Outputs

| Name               | Description                                       |
| ------------------ | ------------------------------------------------- |
| `gh-artifact-name` | The name of the uploaded artifact (same as input) |

## Pipeline ordering

When used with the orchestrator, Mac signing runs **before** GPG signing:

```text
collect -> sign-mac (Apple codesign/productsign/notarize) -> sign (GPG) -> deploy
```

Apple signing modifies files in place, which would invalidate GPG detached signatures (`.asc`) if the order were reversed. The `sign-mac` job overwrites the `build-artifacts` artifact with `overwrite: true`, so the GPG sign job always downloads `build-artifacts` with no conditional logic.

## Setting up Apple secrets

### 1. Export certificates from Keychain Access

On a Mac with your Apple Developer certificates:

```bash
# Application certificate (for codesign)
security find-certificate -c "Developer ID Application" -p > app.pem
security export -k login.keychain -t identities -f pkcs12 -o app.p12

# Installer certificate (for productsign)
security export -k login.keychain -t identities -f pkcs12 -o installer.p12
```

### 2. Base64-encode for GitHub secrets

```bash
base64 -i app.p12 | pbcopy        # paste as APPLE_APPLICATION_CERT
base64 -i installer.p12 | pbcopy  # paste as APPLE_INSTALLER_CERT
```

### 3. Create an app-specific password

Go to [appleid.apple.com](https://appleid.apple.com) > Sign-In and Security > App-Specific Passwords. Generate one and store it as `APPLE_NOTARIZATION_PASSWORD`.

### 4. Required GitHub secrets

| Secret                        | Value                                                                      |
| ----------------------------- | -------------------------------------------------------------------------- |
| `APPLE_APPLICATION_CERT`      | Base64 of Developer ID Application `.p12`                                  |
| `APPLE_CERT_PASSWORD`         | Password used when exporting the `.p12` certificates (omit if unencrypted) |
| `APPLE_INSTALLER_CERT`        | Base64 of Developer ID Installer `.p12` (only needed for `.pkg` signing)   |
| `APPLE_NOTARIZATION_PASSWORD` | App-specific password for notarization                                     |
| `APPLE_ID`                    | Apple Developer account email                                              |
| `APPLE_TEAM_ID`               | Team ID (e.g. `23221RFU77`)                                                |

## Testing

- **Bats tests** (mocked, runs on Linux): `bats .github/workflows/sign-mac-artifacts/tests/bats/`
- **CI dry-run**: `test_sign-mac-artifacts-workflow.yaml` runs on every PR touching sign-mac-artifacts files
- **Manual smoke test**: `test_sign-mac-artifacts-smoke.yaml` (workflow_dispatch) for end-to-end validation with real certificates
