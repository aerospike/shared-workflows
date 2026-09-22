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

| Rule                      | Behaviour                                                                                        |
| ------------------------- | ------------------------------------------------------------------------------------------------ |
| Stage order               | A version must already be at the stage directly before the target. DEV needs no predecessor.     |
| No implicit overwrite     | Promoting into a stage that holds a different version fails, naming the incumbent.               |
| Explicit supersede        | Replacing an incumbent requires `supersede: true` and a `supersede-reason`.                      |
| Released stages are final | Supersede is refused at PREVIEW, INTERNAL and PROD. Ship the fix as a new version.               |
| Gate owner approves       | `supersede: true` requires `gh-environment`, whose reviewers approve the replacement.            |
| Recorded                  | The event is written to an append-only store and attested, and it is written to the run summary. |

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
no tombstone, and un-promoting also deletes that stage's signed `promotion-*.evd`. The event
therefore has to be recorded somewhere the pipeline owns.

Each supersede writes one JSON record to `evidence-repo`, at:

```text
evidence/supersede/<project>/<bundle>/<stage>/<epoch>-<version>.json
```

Fields: `schema`, `project`, `bundle`, `stage`, `replaced` (an array, since a stage can hold
more than one incumbent), `replacedBy`, `at`, `actor`, `reason`, `run`.

Two properties make the record hard to erase quietly:

- **The store is append-only.** `evidence-repo` grants WRITE without DELETE, so Artifactory
  refuses a second write to an existing path. The epoch prefix keeps each write on a fresh
  path. Bundle properties were rejected for this role because they are freely rewritable.
- **The record is attested.** After the write, the record is downloaded, its digest checked
  against what was written, and a GitHub attestation minted over it with predicate type
  `https://aerospike.com/schemas/supersede/v1`. The attestation certificate names the signing
  workflow, so the record cannot be forged by anyone who is not this workflow.

Neither half is sufficient alone: a JFrog platform admin can delete from the store, and a
repository admin can delete an attestation. Erasing the event takes both, and an absence is
visible because the surviving version's record names what it replaced.

The record is written **before** the incumbent is un-promoted. A run that died in between
would otherwise leave the supersede unrecorded.

## Inputs

See `reusable_promote-release-bundle.yaml` for the full input list and defaults.

## Tests

```bash
bats .github/workflows/promote-release-bundle/tests/bats/
```
