# Release Evidence

Trace what a published artifact or release can prove from the signed records JFrog and GitHub already hold. It reads only.

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

`release-evidence.py` accepts a `repo/path`, a full Artifactory URL, `sha256:HEX`, or `bundle:NAME/VERSION@PROJECT` when the release bundle is already known. For a container, point it at the tag's `list.manifest.json`.

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

A JFrog token, resolved in this order: the `jfrog-token` input, then `JFROG_TOKEN` in the environment, then an already-configured JFrog CLI. The last case covers most callers, since `setup-jfrog-cli` usually runs first for OIDC.

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

## Any Artifact, Any Promotion Stage

The target does not have to be public, in a virtual repository, or in a release bundle. An artifact sitting in a `*-dev-local` repository straight from a build is still a valid target, and reports on what it can prove today.

Maturity is read two ways. A promotion attestation is the strong signal. If there is no promotion attestation, the environment segment of the repositories holding the bytes places the artifact in the pipeline.

That produces three distinct lists. The distinction between the last two matters:

| Field            | Meaning                                                                |
| ---------------- | ---------------------------------------------------------------------- |
| `stages_reached` | Stages reached, by promotion record or by repository residence         |
| `pending_stages` | Stages above that point. Not promoted there yet, so no records are due |
| `skipped_stages` | Stages below that point with no record. A gate was passed over         |

For an unsealed artifact, the document will mostly show absences. That is expected, not a failure. Claims are only rendered when the record backing them exists, so an artifact with no supporting record will not imply one.

## Reading The Output

Two distinctions matter when interpreting a document:

- JFrog build-info is not SLSA provenance. Build-info records what a build declared about itself; provenance is an attestation signed by the builder.
- The bundle seal proves custody, not origin. It proves the bytes in the bundle are the bytes that were sealed, not where they came from.

An absent record is not always a gap. A promoted container tag may lose its build properties, INTERNAL is a valid terminal stage, and a stage listed under `pending_stages` is simply not reached yet.

## Tests

```sh
python3 -m unittest discover .github/actions/release-evidence/tests -v
```

Transport is stubbed, so the tests cover what decides a document's claims: stage classification, the pending-versus-skipped distinction, and the rule that no claim renders without its record.
