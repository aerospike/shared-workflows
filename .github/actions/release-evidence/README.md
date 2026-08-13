# Release Evidence

Trace what a published artifact or release can prove, using the signed records JFrog and GitHub already hold. Reads only; it publishes nothing and changes nothing.

For any target it reports the digest, every repository holding those bytes, the release bundle seal, the promotion history with approvers, SLSA provenance where it exists, and the pull request that authorized the change.

## Scripts

Both scripts run standalone as well as through the action. They need `curl`, `jq`, `python3`, and `gh`.

| Script                | Scope                                                                                |
| --------------------- | ------------------------------------------------------------------------------------ |
| `verify-artifact.sh`  | One artifact: digest, holding repositories, commit, seal, promotions, provenance, PR |
| `release-evidence.py` | The whole release the artifact belongs to, as a markdown or JSON document            |

```sh
JFROG_TOKEN=<token> ./verify-artifact.sh clients-pypi-dev-local/aerospike/16.0.1/aerospike-16.0.1.whl
JFROG_TOKEN=<token> ./release-evidence.py bundle:my-release/1.2.3@myproject --format json
```

`release-evidence.py` accepts a `repo/path`, a full Artifactory URL, `sha256:HEX`, or `bundle:NAME/VERSION@PROJECT` when the release bundle is already known. For a container, point it at the tag's `list.manifest.json`, whose sha256 is the index digest GitHub attests.

JFrog auth comes from `JFROG_TOKEN`. GitHub auth comes from the `gh` CLI or `GITHUB_TOKEN`.

## Action Inputs

| Input         | Required | Default                      | Description                                                        |
| ------------- | -------- | ---------------------------- | ------------------------------------------------------------------ |
| `target`      | Yes      | -                            | Artifact path, URL, `sha256:HEX`, or `bundle:NAME/VERSION@PROJECT` |
| `format`      | No       | `markdown`                   | `markdown` or `json`                                               |
| `about`       | No       | -                            | One clause describing the thing, used in the opening sentence      |
| `output-path` | No       | -                            | Write the document here instead of stdout                          |
| `jf-url`      | No       | `https://aerospike.jfrog.io` | JFrog platform URL                                                 |
| `jfrog-token` | No       | -                            | Overrides `JFROG_TOKEN` and the JFrog CLI config                   |

| Output     | Description                                                |
| ---------- | ---------------------------------------------------------- |
| `document` | Path to the written document, empty when it went to stdout |

## Prerequisites

A JFrog token, resolved in this order: the `jfrog-token` input, then `JFROG_TOKEN` in the environment, then an already-configured JFrog CLI. The last case covers most callers, since `setup-jfrog-cli` has usually run for OIDC before this step.

SLSA provenance lookups use `gh`, so the job needs a token that can read attestations on the repository that built the artifact.

## Example

```yaml
- name: Setup JFrog CLI
  uses: jfrog/setup-jfrog-cli@<sha> # v4.8.1
  env:
    JF_URL: https://aerospike.jfrog.io
  with:
    oidc-provider-name: gh-aerospike
    oidc-audience: aerospike

- name: Record release evidence
  uses: aerospike/shared-workflows/.github/actions/release-evidence@<sha> # version
  with:
    target: bundle:${{ inputs.bundle-name }}/${{ inputs.bundle-version }}@${{ inputs.jf-project }}
    format: json
    output-path: evidence/${{ inputs.bundle-name }}.json
  env:
    GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

## Reading The Output

Two distinctions matter when interpreting a document:

- JFrog build-info is not SLSA provenance. Build-info records what a build declared about itself; provenance is an attestation signed by the builder.
- The bundle seal proves custody, not origin. It proves the bytes in the bundle are the bytes that were sealed, not where they came from.

An absent record is not automatically a gap. A promoted container tag loses its build properties, and INTERNAL is a valid terminal stage rather than a missing PROD.
