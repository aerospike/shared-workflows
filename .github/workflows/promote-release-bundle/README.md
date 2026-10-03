# Promote Release Bundle

Promotes a JFrog release bundle to a stage, and refuses a promotion that skips a required
stage. Use `reusable_promote-release-bundle.yaml` rather than calling
`jf release-bundle-promote` directly. The order check is in the workflow, and only a reusable
workflow can set a GitHub environment on the promotion job, which is how a gate owner
approves it.

## Usage

```yaml
promote-to-test:
  needs: create-release-bundle
  permissions:
    contents: read
    id-token: write
  uses: aerospike/shared-workflows/.github/workflows/reusable_promote-release-bundle.yaml@<sha> # vX.Y.Z
  with:
    gh-workflows-ref: <sha> # vX.Y.Z, the same ref as uses:
    jf-bundle-name: my-release
    jf-project: my-project
    version: ${{ needs.create-release-bundle.outputs.bundle-version }}
    target-stage: TEST
    gh-environment: promote-test
```

## Rules

| Rule                 | Behaviour                                                                                           |
| -------------------- | --------------------------------------------------------------------------------------------------- |
| Required stages      | STAGE requires the version at TEST. PREVIEW, INTERNAL and PROD require it at STAGE.                 |
| Optional stages      | DEV and PREVIEW can be skipped. A version can go straight to TEST, and from STAGE straight to PROD. |
| Already promoted     | Promoting a version to a stage it is already at does nothing.                                       |
| Records must be read | If the promotion records cannot be read, the promotion is refused.                                  |
| Gate owner           | `gh-environment` attaches a GitHub environment, so its required reviewers approve the promotion.    |
| No silent overwrite  | JFrog refuses a promotion that would overwrite another version's files at the same paths.           |

Skipping DEV keeps the dev-local paths unlocked, so a rebuild of the same version can
deploy again. A promotion to DEV locks those paths until it is removed.

## Inputs

See `reusable_promote-release-bundle.yaml` for the full input list and defaults.

## Tests

```bash
bats .github/workflows/promote-release-bundle/tests/bats/
```
