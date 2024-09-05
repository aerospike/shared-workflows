# Setup GPG composite Action

This composite action will setup your github action to use a supplied gpg key.

## Supported Platforms
- GPG
- rpmsign/rpm
- debsign

If you need a platform not listed above, please contact the maintainers!

## Example Usage

```yaml
on: [push]

jobs:
  hello_world_job:
    runs-on: ubuntu-latest
    name: A job to say hello
    steps:
      - uses: actions/checkout@v4
      - id: foo
        uses: aerospike/shared-workflows/devops/setup-gpg@latest
        with:
          gpg-private-key: ${{ secret.gpg_key }}
          gpg-key-pass: ${{ secret.gpg_pass }}
          gpg-key-name: "Aerospike"
```

### Example RPM and GPG useage
```yaml
name: GPG sign rpm
on: workflow_dispatch
jobs:
  signing:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@master
      - name: Install GPG
        run: sudo apt-get update && sudo apt-get install gnupg -y
      - name: setup GPG
        uses: aerospike/shared-workflows/devops/setup-gpg@feat/setup-gpg-composite
        with:
          gpg-private-key: ${{ secrets.GPG_PRIVATE_KEY }}
          gpg-key-pass: ${{ secrets.GPG_PASS }}
          gpg-key-name: "aerospiketest"
      - name: Sign RPM Package
        env:
          GPG_TTY: no-tty
          GPG_PASSPHRASE: ${{ secrets.GPG_PASS }}
        run: |
          # sign a gpg
          gpg --detach-sign --no-tty --batch --yes --passphrase "$GPG_PASSPHRASE" my.rpm
```
