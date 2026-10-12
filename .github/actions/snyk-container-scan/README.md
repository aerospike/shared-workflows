# Snyk Container Scan

Run a Snyk container image security scan on a promoted artifact and report what it found. It
reads only: it tests the image, and when asked records it in the Snyk portal. It does not
promote, tag, or delete anything.

For one image it reports a `PASS`/`FAIL` verdict and the count of unique findings at each
severity. `FAIL` means there is at least one finding at or above the severity threshold. The
calling workflow gates on the verdict (see [Gating On The Verdict](#gating-on-the-verdict)) —
this action never promotes or blocks on its own.

## Script

`scan.sh` runs standalone as well as through the action. It needs `snyk`, `docker`, `jq`,
`python3`, and `curl`. Through the action, a pinned, GPG-verified `snyk` is always installed
and prepended to PATH — a preexisting `snyk` on the runner is never trusted. Run `scan.sh`
standalone with your own `snyk` on PATH.

```sh
SNYK_TOKEN=<token> JFROG_TOKEN=<token> \
  IMAGE=database-docker-prod-public-local/aerospike-aql:9.2.9-3 \
  ./scan.sh database-docker-prod-public-local/aerospike-aql:9.2.9-3
```

`summarize.py` turns the Snyk JSON report into the verdict and counts, and is where the
PASS/FAIL logic lives. It runs on a report file alone, with no network:

```sh
./summarize.py report.json --severity-threshold high
```

Snyk auth comes from `SNYK_TOKEN`. JFrog auth, used only to `docker login` so a private image
can be pulled, comes from `JFROG_TOKEN`; skip it when the runner is already authenticated to
the registry.

## Action Inputs

| Input                | Required | Default                      | Description                                                                       |
| -------------------- | -------- | ---------------------------- | --------------------------------------------------------------------------------- |
| `image`              | Yes      | -                            | Container image reference, host optional (e.g. `repo/name:tag`)                   |
| `severity-threshold` | No       | `high`                       | Lowest severity that counts against the verdict                                   |
| `fail-on-issues`     | No       | `true`                       | Exit non-zero on a `FAIL` verdict. A caller that owns the gate sets this `false`. |
| `monitor`            | No       | `true`                       | Also `snyk container monitor` to record the image in the Snyk portal              |
| `platform`           | No       | -                            | Platform to scan for a multi-arch tag (e.g. `linux/amd64`)                        |
| `sarif-output-path`  | No       | -                            | Write SARIF here for a later code-scanning upload                                 |
| `json-output-path`   | No       | -                            | Keep the raw Snyk JSON report here                                                |
| `timeout`            | No       | -                            | Wall-clock cap (e.g. `10m`); on expiry the verdict is `TIMEOUT`                   |
| `jf-url`             | No       | `https://aerospike.jfrog.io` | JFrog platform URL; its host is the registry for `docker login`                   |
| `jfrog-token`        | No       | -                            | Overrides `JFROG_TOKEN`. Skip when the runner is already authenticated.           |
| `registry-username`  | No       | token subject                | `docker login` username; defaults to the JFrog token's subject                    |
| `snyk-token`         | No       | -                            | Overrides `SNYK_TOKEN`                                                            |
| `snyk-org`           | No       | -                            | Snyk org id, required only when `monitor` is true                                 |
| `snyk-cli-version`   | No       | pinned                       | Break-glass CLI version override; still GPG-verified and bake-checked             |
| `min-age-hours`      | No       | `48`                         | Refuse a CLI release younger than this (bake); `0` disables                       |

| Output      | Description                                                                     |
| ----------- | ------------------------------------------------------------------------------- |
| `verdict`   | `PASS` or `FAIL`. `FAIL` means a finding at or above the threshold. Gate on it. |
| `critical`  | Count of unique critical-severity findings                                      |
| `high`      | Count of unique high-severity findings                                          |
| `medium`    | Count of unique medium-severity findings                                        |
| `low`       | Count of unique low-severity findings                                           |
| `total`     | Count of unique findings across all severities                                  |
| `sarif`     | Path to the written SARIF, empty when `sarif-output-path` was not set           |
| `report`    | Path to the raw Snyk JSON report                                                |
| `monitored` | Snyk portal URL for the monitored project, empty when `monitor` was off         |

## Prerequisites

A Snyk API token, from the `snyk-token` input or `SNYK_TOKEN` in the environment.

To pull a private image, registry auth: either a JFrog token (`jfrog-token` input or
`JFROG_TOKEN`) that the action uses to `docker login`, or a runner already logged in to the
registry (for example after `setup-jfrog-cli`).

`monitor` needs `snyk-org`. The action installs its own verified Snyk CLI, so the runner needs
only `docker`, `jq`, `python3`, `curl`, and `gpg` — all present on `ubuntu-latest`.

## Example

```yaml
- name: Setup JFrog CLI
  uses: jfrog/setup-jfrog-cli@<sha> # v4.8.1
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
    snyk-org: ${{ vars.SNYK_ORG_ID }}
  env:
    SNYK_TOKEN: ${{ secrets.SNYK_TOKEN }}
    JFROG_TOKEN: ${{ secrets.JFROG_TOKEN }}

- name: Upload to code scanning
  if: ${{ !cancelled() && steps.scan.outputs.sarif != '' }}
  continue-on-error: true # private repo without GHAS degrades softly
  uses: github/codeql-action/upload-sarif@<sha> # v3
  with:
    sarif_file: ${{ steps.scan.outputs.sarif }}
    category: snyk-container
```

Like `release-evidence`, this action leaves the edges to the caller: `setup-jfrog-cli` for
OIDC, and `upload-sarif` for code scanning. The action only produces the verdict and the SARIF
path.

## Gating On The Verdict

`FAIL` is the only status that blocks — it means a finding sits at or above the threshold.
`PASS` means nothing did. Standalone, `fail-on-issues` (default `true`) already exits non-zero
on `FAIL`, so a failing scan fails the job. To gate explicitly on the output instead:

```yaml
- name: Block the promotion on a failing scan
  if: startsWith(steps.scan.outputs.verdict, 'FAIL')
  run: |
    echo "::error::${{ steps.scan.outputs.verdict }}: ${{ steps.scan.outputs.critical }} critical, ${{ steps.scan.outputs.high }} high"
    exit 1
```

The blocking policy — which severity fails, and whether a `FAIL` actually stops a promotion —
lives in the calling workflow, not here. Set `severity-threshold` to the level the caller wants
(any finding at or above it flips the verdict to `FAIL`) and set `fail-on-issues: false` when
the caller reads the verdict output and makes the decision itself.

## Versioning The Snyk CLI

The trust anchor is **Snyk's GPG signing key**, committed as
[`snyk-code-signing.asc`](./snyk-code-signing.asc) and pinned by fingerprint in
[`snyk-cli.pin`](./snyk-cli.pin). The install step:

1. enforces the **minimum bake** — refuses a release younger than `min-age-hours` (default 48h)
   so a freshly published, possibly compromised CLI is never adopted on day zero
   ([`verify_cli_age.py`](./verify_cli_age.py));
2. imports the committed key and asserts its fingerprint equals `SNYK_GPG_FINGERPRINT` — the
   one out-of-band trust decision;
3. downloads the release's signed checksums manifest (`sha256sums.txt.asc`) and verifies the
   signature against that key;
4. downloads the binary and checks it against the now-trusted checksum from the manifest.

Any failure fails loudly and the binary is deleted — it never falls back to an unverified or
`latest` CLI. Because the key verifies _any_ version, there are **no per-version checksums to
maintain**: bumping the CLI is a one-line change to `SNYK_CLI_DEFAULT_VERSION` in
`snyk-cli.pin`, not a hash update.

### Who can bump it

`snyk-cli.pin` and this action are owned by `@aerospike/seceng` in
[CODEOWNERS](../../CODEOWNERS), so changing the pinned version requires a security-team-approved
PR to this repo. Consumer teams reference the shared workflow by tag/SHA and cannot change the
version — this is deliberate, so the CLI at the prod gate is a security decision. The
`snyk-cli-version` input exists only as a break-glass override for standalone/non-prod callers;
a promotion workflow does not plumb it, so promotions always use the pinned version, and even an
override is GPG-verified **and** bake-checked.

### Bump policy

Point `SNYK_CLI_DEFAULT_VERSION` at the newest release that has passed the **2-day bake**
(matching the org's StepSecurity cooldown). The bake is **enforced at install time** by
`min-age-hours` (default 48h), so this is not merely convention — a too-new pin fails the run:

```sh
# newest release, then confirm it is >= 2 days old before pinning it
gh api repos/snyk/cli/releases --jq '.[] | "\(.tag_name)\t\(.published_at)"' | head
```

A scheduled workflow can open the bump PR automatically (pick newest release ≥ 2 days old, run
this action's tests); only `@aerospike/seceng` can merge it. There are no digests to recompute,
so nothing can drift.

### Key rotation

`SNYK_GPG_FINGERPRINT` changes only when Snyk rotates its code-signing key (the current key
expires **2027-01-06**) — roughly a once-every-two-years event, not a per-release one. When it
rotates, confirm the new fingerprint against Snyk's official documentation, then update both
`snyk-code-signing.asc` and the fingerprint in `snyk-cli.pin` in one seceng-approved PR.
