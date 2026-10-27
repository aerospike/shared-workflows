# Snyk Container Scan

Scan a promoted container image with the **official [`snyk/actions/docker`](https://github.com/snyk/actions)** action and report what it found. It reads only: it tests the image, and when asked records it in the Snyk portal. It does not promote, tag, or delete anything.

For one image it reports a `PASS`/`FAIL` verdict and the count of unique findings at each severity. `FAIL` means there is at least one finding at or above the severity threshold. The calling workflow gates on the verdict (see [Gating On The Verdict](#gating-on-the-verdict)) — this action never promotes or blocks on its own.

## How it works

1. The official Snyk action runs `snyk container test <image>` (in Snyk's maintained image) and writes a JSON report.
2. [`summarize.py`](./summarize.py) turns that JSON into the verdict and per-severity counts — unique by vuln id (a CVE reported down several dependency paths counts once); a threshold blocks on its own level and everything above it.
3. Optionally, a second call runs `snyk container monitor` to record the image in the Snyk portal for continuous monitoring.

`summarize.py` runs on a report file alone, with no network:

```sh
./summarize.py snyk-report.json --severity-threshold high
```

## Registry auth is the caller's job

The official action pulls the image via the Docker daemon, so for a **private** image the caller must authenticate to the registry **before** this action — e.g. `docker login`, or `setup-jfrog-cli` with OIDC. The [reusable security-scan workflow](../../workflows/reusable_security-scan.yaml) wires that up for you. Snyk auth comes from `SNYK_TOKEN` (the `snyk-token` input or the environment).

## Action Inputs

| Input                | Required | Default | Description                                                                  |
| -------------------- | -------- | ------- | ---------------------------------------------------------------------------- |
| `image`              | Yes      | -       | Container image reference (e.g. `repo/name:tag`)                             |
| `severity-threshold` | No       | `high`  | Lowest severity that counts against the verdict                              |
| `fail-on-issues`     | No       | `true`  | Exit non-zero on a `FAIL` verdict. A caller that owns the gate sets `false`. |
| `monitor`            | No       | `false` | Also `snyk container monitor` to record the image in the Snyk portal         |
| `platform`           | No       | -       | Platform to scan for a multi-arch tag (e.g. `linux/amd64`)                   |
| `sarif-output-path`  | No       | -       | Write SARIF here for a later code-scanning upload                            |
| `snyk-org`           | No       | -       | Snyk org id, required only when `monitor` is true                            |
| `snyk-token`         | No       | -       | Overrides `SNYK_TOKEN`                                                       |

| Output                                 | Description                                                                     |
| -------------------------------------- | ------------------------------------------------------------------------------- |
| `verdict`                              | `PASS` or `FAIL`. `FAIL` means a finding at or above the threshold. Gate on it. |
| `critical` / `high` / `medium` / `low` | Count of unique findings at that severity                                       |
| `total`                                | Count of unique findings across all severities                                  |
| `report`                               | Path to the raw Snyk JSON report                                                |
| `sarif`                                | Path to the written SARIF, empty when `sarif-output-path` was not set           |

## Versioning the Snyk action

The scanner is the official `snyk/actions/docker`, **SHA-pinned** in [`action.yaml`](./action.yaml) with a date comment and kept current by Dependabot — the same way every other third-party action in this repo is pinned. The underlying Snyk CLI version is whatever that pinned action ships. (We intentionally do not self-manage the CLI binary; see the PR history for the trade-off vs. a GPG-verified self-hosted install.)

## Example

```yaml
# The caller authenticates to the registry first (private image), then scans.
- name: Setup JFrog CLI
  uses: jfrog/setup-jfrog-cli@<sha> # v4
  env:
    JF_URL: https://aerospike.jfrog.io
  with:
    oidc-provider-name: gh-aerospike
    oidc-audience: aerospike

- name: Scan the promoted image
  id: scan
  uses: aerospike/shared-workflows/.github/actions/snyk-container-scan@<sha> # version
  with:
    image: database-docker-prod-public-local/aerospike-aql:${{ inputs.version }}
    severity-threshold: high
    platform: linux/amd64
    sarif-output-path: snyk.sarif
  env:
    SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}

- name: Upload to code scanning
  if: ${{ !cancelled() && steps.scan.outputs.sarif != '' }}
  continue-on-error: true # private repo without GHAS degrades softly
  uses: github/codeql-action/upload-sarif@<sha> # v3
  with:
    sarif_file: ${{ steps.scan.outputs.sarif }}
    category: snyk-container
```

## Gating On The Verdict

`FAIL` is the only status that blocks — it means a finding sits at or above the threshold. `PASS` means nothing did. Standalone, `fail-on-issues` (default `true`) already exits non-zero on `FAIL`. To gate explicitly on the output instead:

```yaml
- name: Block the promotion on a failing scan
  if: startsWith(steps.scan.outputs.verdict, 'FAIL')
  run: |
    echo "::error::${{ steps.scan.outputs.verdict }}: ${{ steps.scan.outputs.critical }} critical, ${{ steps.scan.outputs.high }} high"
    exit 1
```

The blocking policy — which severity fails, and whether a `FAIL` actually stops a promotion — lives in the calling workflow, not here. Set `severity-threshold` to the level the caller wants, and set `fail-on-issues: false` when the caller reads the verdict output and makes the decision itself.
