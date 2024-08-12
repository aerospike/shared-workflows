# Setup GPG composite Action

This composite action will setup your github action to use a supplied gpg key.

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
        uses: aerospike/devops/setup-pgp@latest
        with:
          private-key: ${{ secret.gpg_key }}
          key-pass: ${{ secret.gpg_pass }}
          key-name: "aerospike"
```
