# Setup GPG composite Action

This composite action imports a supplied GPG key and configures the runner for non-interactive GPG signing and RPM package signing in subsequent steps.

## Requirements

- **Ubuntu 22.04 only.** The action checks the runner OS and fails on any other version.

## What it does

- Installs `gnupg`, `rpm`, and supporting tools.
- Imports the private key, sets it as the default key, and configures loopback pinentry plus a passphrase file for batch (non-interactive) signing.
- Writes `~/.rpmmacros` so `rpm --addsign` works with the imported key.
- Imports the public key for verification.

## Inputs

| Input             | Required | Description                                              |
| ----------------- | -------- | -------------------------------------------------------- |
| `gpg-private-key` | Yes      | GPG private key (ASCII-armored) to import for signing    |
| `gpg-key-pass`    | Yes      | Passphrase for the private key                           |
| `gpg-public-key`  | Yes      | GPG public key (ASCII-armored) imported for verification |

The signing key name and fingerprint are extracted automatically from the imported key; there is no key-name input.

## Outputs

This action produces no outputs. It configures GPG, the RPM signing macros, and gpg-agent for use by later steps in the same job.

## Example Usage

```yaml
on: [push]

jobs:
  sign:
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@v4
      - name: Set up GPG
        uses: aerospike/shared-workflows/.github/actions/setup-gpg@v3
        with:
          gpg-private-key: ${{ secrets.GPG_PRIVATE_KEY }}
          gpg-key-pass: ${{ secrets.GPG_PASS }}
          gpg-public-key: ${{ secrets.GPG_PUBLIC_KEY }}
      - name: Sign an RPM
        run: rpm --addsign my-package.rpm
```
