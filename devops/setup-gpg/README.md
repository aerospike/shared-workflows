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
