# Fetch conformance fixtures

Download one pinned [aerospike-client-conformance](https://github.com/aerospike/aerospike-client-conformance) release into the workspace.

The release zip is published to JFrog generic by that repository's tag workflow:

```text
<jf-project>-generic-dev-local/<package-name>/<version>/<package-name>-<version>.zip
```

The default path for fixture set `0.1.0` is:

```text
database-generic-dev-local/aerospike-client-conformance/0.1.0/aerospike-client-conformance-0.1.0.zip
```

The zip has a single top-level directory. This action strips it, so `fixtures-directory` has `VERSION` at its root, the same shape as a checkout of that release. Point a client runner at that directory. The Java runner checks `VERSION` before it reads any row.

The caller workflow needs `id-token: write` so the JFrog CLI can authenticate with OIDC. `dry-run` prints the artifact path and does not download.

## Inputs

| Input                | Required | Default                        | Description                                                  |
| -------------------- | -------- | ------------------------------ | ------------------------------------------------------------ |
| `version`            | Yes      | —                              | Fixture set version, `MAJOR.MINOR.PATCH`, with no `v` prefix |
| `destination`        | No       | `conformance-fixtures`         | Workspace-relative directory to extract into                 |
| `dry-run`            | No       | `false`                        | Print the artifact path and skip the download                |
| `jf-project`         | No       | `database`                     | Artifactory project that publishes the fixture set           |
| `jf-url`             | No       | `https://aerospike.jfrog.io`   | JFrog platform URL                                           |
| `oidc-audience`      | No       | `""`                           | JFrog OIDC audience. Required unless `dry-run` is true       |
| `oidc-provider-name` | No       | `""`                           | JFrog OIDC provider name. Required unless `dry-run` is true  |
| `package-name`       | No       | `aerospike-client-conformance` | Release artifact name                                        |

## Outputs

| Output                | Description                                               |
| --------------------- | --------------------------------------------------------- |
| `artifact-path`       | Artifactory path of the release zip                       |
| `fixtures-directory`  | Absolute directory containing `VERSION`. Empty on dry-run |
| `fixture-set-version` | Version read from the release. Empty on dry-run           |

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
          version: 0.1.0
          oidc-provider-name: gh-aerospike
          oidc-audience: aerospike

      - name: Run the Java conformance driver
        run: >
          mvn -pl client test -Dtest=ConformanceTest
          -Dconformance.dir=${{ steps.fixtures.outputs.fixtures-directory }}
```

Pair this with [collect-conformance-report](../collect-conformance-report/README.md) after the runner writes `conformance-report.json`.
