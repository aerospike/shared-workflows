# Promote Release Bundle

`reusable_promote-release-bundle.yaml` promotes a JFrog release bundle version to a stage and refuses
a promotion that skips a required stage. The `promote-release-bundle` composite action and a direct
`jf release-bundle-promote` skip that check.

## Usage

```yaml
promote-to-test:
  needs: create-release-bundle
  permissions:
    attestations: write
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

The calling job must grant `attestations: write`, or the run ends in `startup_failure`. The inputs
and their defaults are in `reusable_promote-release-bundle.yaml`.

## Rules

- STAGE requires TEST. PREVIEW, INTERNAL and PROD require STAGE. DEV and PREVIEW are optional.
- A stage counts only when completed promotions to it hold every artifact of the version.
- Promoting to a stage that already holds the whole version does nothing.
- If the promotion records cannot be read, the promotion is refused.
- The job fails unless the shared-workflows checkout at `gh-workflows-ref` is the commit the workflow
  runs from.
- Promotions of one bundle to one stage run one at a time.
- `gh-environment` puts the job in a GitHub environment, so its required reviewers approve the
  promotion. Give the environment required reviewers: GitHub creates a missing environment without
  any.

Skipping DEV keeps the dev-local paths unlocked, so a rebuild of the same version can deploy again.

## Tests

```bash
bats .github/workflows/promote-release-bundle/tests/bats/
```
