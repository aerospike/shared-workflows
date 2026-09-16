# Promote Release Bundle

Advances a JFrog release bundle one promotion stage forward. Refuses to overwrite a
stage that already holds a different version unless a supersede is explicitly requested.

Use `reusable_promote-release-bundle.yaml` rather than calling
`jf release-bundle-promote` directly. The guards below live in the workflow, and the
GitHub environment approval is only available to a callable workflow.

## Usage

```yaml
promote-to-test:
  uses: aerospike/shared-workflows/.github/workflows/reusable_promote-release-bundle.yaml@<sha> # v3.8.0
  with:
    gh-workflows-ref: v3.8.0
    jf-bundle-name: my-release
    jf-project: my-project
    version: 1.2.3
    target-stage: TEST
    gh-environment: promote-test
  secrets: inherit
```

Replacing a build that failed a gate:

```yaml
supersede-at-test:
  uses: aerospike/shared-workflows/.github/workflows/reusable_promote-release-bundle.yaml@<sha> # v3.8.0
  with:
    gh-workflows-ref: v3.8.0
    jf-bundle-name: my-release
    jf-project: my-project
    version: 1.2.3-1794531-2 # create-release-bundle bundle-version output
    target-stage: TEST
    gh-environment: promote-test
    supersede: true
    supersede-reason: rejected by QE, bad default in shipped config
  secrets: inherit
```

## What it enforces

| Rule                      | Behaviour                                                                                                        |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| Stage order               | A version must already be at the stage directly before the target. DEV needs no predecessor.                     |
| No implicit overwrite     | Promoting into a stage that holds a different version fails, naming the incumbent.                               |
| Explicit supersede        | Replacing an incumbent requires `supersede: true` and a `supersede-reason`.                                      |
| Released stages are final | Supersede is refused at PREVIEW, INTERNAL and PROD. Ship the fix as a new version.                               |
| Gate owner approves       | `supersede: true` requires `gh-environment`, whose reviewers approve the replacement.                            |
| Recorded                  | Both the superseding and superseded versions are annotated with the event, and it is written to the run summary. |

Stage order is a graph, not a line. PREVIEW and INTERNAL both follow STAGE, and PROD
follows PREVIEW.

## Superseding

A supersede removes the incumbent's promotion to the target stage only. Other stages keep
their promotions and keep serving the incumbent, so nothing downstream goes dark while a
replacement is prepared.

The incumbent's bundle keeps its own signed copy of every artifact, so it stays promotable
and rolling back is promoting it again.

Never delete a release bundle to clear a promotion conflict. The bundle holds the version's
only durable copy and its provenance.

## The supersede record

Promotion records in Artifactory are current state, so removing a promotion erases it with
no tombstone. The event is therefore written as bundle properties, which persist with the
bundle:

- On the superseding version: `supersede.replaced`, `supersede.stage`, `supersede.at`,
  `supersede.actor`, `supersede.reason`
- On the superseded version: `supersede.replacedBy` and the same four fields

A version superseded at more than one stage keeps only the most recent set of properties.
The run summary carries the full per-run trail.

## Inputs

See `reusable_promote-release-bundle.yaml` for the full input list and defaults.

## Tests

```bash
bats .github/workflows/promote-release-bundle/tests/bats/
```
