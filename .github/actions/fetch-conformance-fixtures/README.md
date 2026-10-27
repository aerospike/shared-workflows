# Fetch conformance fixtures

Download one pinned [aerospike-client-conformance](https://github.com/aerospike/aerospike-client-conformance) release from JFrog and extract it so `fixtures-directory` has `VERSION` at its root, the same shape as a checkout of that release.

The release is `database-generic-dev-local/aerospike-client-conformance/<version>/aerospike-client-conformance-<version>.zip`, published by that repository's tag workflow. Pin the version your client runner expects; the Java runner checks `VERSION` before it reads any row. The action fails if the release contains a symlink, if its `VERSION` does not match, or if `destination` already exists.

The caller needs `id-token: write` for JFrog OIDC. Fork pull requests do not get OIDC tokens, so the download fails there rather than skipping.

## Inputs

| Input                | Required | Default                | Description                                                  |
| -------------------- | -------- | ---------------------- | ------------------------------------------------------------ |
| `version`            | Yes      | —                      | Fixture set version, `MAJOR.MINOR.PATCH`, with no `v` prefix |
| `oidc-provider-name` | Yes      | —                      | JFrog OIDC provider name                                     |
| `oidc-audience`      | Yes      | —                      | JFrog OIDC audience                                          |
| `destination`        | No       | `conformance-fixtures` | Workspace-relative directory to extract into                 |

## Outputs

| Output               | Description                             |
| -------------------- | --------------------------------------- |
| `fixtures-directory` | Absolute directory containing `VERSION` |

## Example

```yaml
permissions:
  contents: read
  id-token: write

jobs:
  conformance:
    runs-on: ubuntu-22.04
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1

      - id: fixtures
        uses: aerospike/shared-workflows/.github/actions/fetch-conformance-fixtures@<sha> # vX.Y.Z
        with:
          version: 1.0.0
          oidc-provider-name: ${{ vars.JFROG_OIDC_PROVIDER }}
          oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}

      - name: Run the Java conformance driver
        run: >
          mvn -pl client test -Dtest=ConformanceTest
          -Dconformance.dir=${{ steps.fixtures.outputs.fixtures-directory }}
```

Pair it with [collect-conformance-report](../collect-conformance-report/README.md), passing the same `fixtures-directory`.
