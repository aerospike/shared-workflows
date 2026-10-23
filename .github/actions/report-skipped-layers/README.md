# Report skipped layers

Append a job summary row, and a notice annotation, for each test layer that did not run because a secret is absent. Each row names the layer, the tests that did not run, and why.

A fork PR gets no Enterprise feature key, no AKO image pull, and no JFrog OIDC. Without this step, its pipeline goes green having proved a fraction of what the branch pipeline proves, and nothing says so. This is the layer-level version of the conformance rule that a runtime which cannot run a fixture records `unsupported` with a reason instead of skipping it silently (see `collect-conformance-report`).

## Behavior

| `layers` input                                       | Job                                                                       |
| ---------------------------------------------------- | ------------------------------------------------------------------------- |
| `[]`                                                 | Stays green. The summary says no secret-gated layer was skipped.          |
| One or more valid rows                               | Stays green. One table row and one `::notice::` per skipped layer.        |
| Invalid JSON, not an array, or a row missing a field | Fails. A skipped-layer report that cannot be read must not pass silently. |

A skip is expected on a fork PR, so the action emits `::notice::`, never `::warning::` or `::error::`. The markdown goes to `$GITHUB_STEP_SUMMARY` and to stdout, so it also appears in the step log.

The action does not read secrets. The caller decides what was skipped and passes the rows in. Keep the condition that skips a layer and the condition that reports it in one place, so they cannot drift.

GitHub does not allow `secrets.*` in a job or step `if:`. Expose presence as a job-level `env` value, for example `HAS_FEATURES_CONF: ${{ secrets.AEROSPIKE_SERVER_FEATURES_CONF != '' }}`, and test `env.HAS_FEATURES_CONF` in the step that skips the layer and in the step that builds the rows. Use `github.event.pull_request.head.repo.fork` for gates that are absent on every fork PR, such as JFrog OIDC.

## Inputs

| Input    | Required | Default | Description                                                                                            |
| -------- | -------- | ------- | ------------------------------------------------------------------------------------------------------ |
| `layers` | Yes      | —       | JSON array, one object per skipped layer. Pass `[]` when nothing was skipped, so the step always runs. |

Each object has these string fields, all required:

| Field    | Example                                   |
| -------- | ----------------------------------------- |
| `layer`  | `L2 EE`                                   |
| `tests`  | `N-6, N-14, multi-node cluster`           |
| `reason` | `Enterprise feature key secret is absent` |

## Outputs

| Output          | Description                       |
| --------------- | --------------------------------- |
| `skipped-count` | Number of skipped layers reported |

## Known gates

These are the secret-gated layers in the pluggable discovery test strategy. The action does not know about them; they are listed here so a caller can copy the rows.

| Layer   | Tests not run                   | Gate                                                                     |
| ------- | ------------------------------- | ------------------------------------------------------------------------ |
| `L2 EE` | `N-6, N-14, multi-node cluster` | Enterprise feature key secret                                            |
| `L3`    | K suite                         | AKO image pull and JFrog OIDC (no fork PR has them), and the feature key |

## Example

Run the step with `if: always()` in the job that would have run the gated layers, after the gate is decided.

```yaml
env:
  HAS_FEATURES_CONF: ${{ secrets.AEROSPIKE_SERVER_FEATURES_CONF != '' }}
  IS_FORK_PR: ${{ github.event.pull_request.head.repo.fork == true }}

steps:
  # ... the L2 EE and L3 steps use the same HAS_FEATURES_CONF / IS_FORK_PR conditions ...

  - name: List skipped layers
    id: skipped
    if: always()
    run: |
      layers='[]'
      if [[ "$HAS_FEATURES_CONF" != true ]]; then
        layers=$(jq -c '. + [{layer: "L2 EE", tests: "N-6, N-14, multi-node cluster", reason: "Enterprise feature key secret is absent"}]' <<< "$layers")
      fi
      if [[ "$IS_FORK_PR" == true ]]; then
        layers=$(jq -c '. + [{layer: "L3", tests: "K suite", reason: "fork PRs get no AKO image pull, JFrog OIDC, or feature key"}]' <<< "$layers")
      elif [[ "$HAS_FEATURES_CONF" != true ]]; then
        layers=$(jq -c '. + [{layer: "L3", tests: "K suite", reason: "Enterprise feature key secret is absent"}]' <<< "$layers")
      fi
      echo "layers=${layers}" >> "$GITHUB_OUTPUT"

  - name: Report skipped layers
    if: always()
    uses: aerospike/shared-workflows/.github/actions/report-skipped-layers@<sha> # vX.Y.Z
    with:
      layers: ${{ steps.skipped.outputs.layers }}
```
