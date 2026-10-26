# Promote Release Bundle

`reusable_promote-release-bundle.yaml` promotes a JFrog release bundle version to a stage and refuses
a promotion that skips a required stage. With `supersede`, it replaces an earlier revision of the
same release at that stage and records the replacement. The `promote-release-bundle` composite action
and a direct `jf release-bundle-promote` skip the stage check and cannot supersede.

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

## Supersede

A stage holds one artifact per path. When a rebuild of a release, a new bundle revision, goes to a
stage that holds an earlier revision, JFrog refuses the path collision. Set `supersede` to replace
the earlier revision:

```yaml
with:
  target-stage: TEST
  supersede: true
  supersede-reason: Rebuilt with the fix for CVE-2026-1234
  gh-environment: promote-test
```

- The versions replaced are the other versions of the bundle at the target stage that share an
  artifact path with this version. Other releases at the stage are left alone.
- They are un-promoted, then this version is promoted. If either step fails, the versions already
  un-promoted are promoted again and no record is written.
- After the swap, the workflow writes a record of it, attests the record, and stores both in
  `release-evidence-local` under `evidence/supersede/<project>/<bundle>/<stage>/`. The attestation
  is stored beside the record as `<record>.sigstore.json`.
- Supersede is allowed at DEV, TEST and STAGE. A version past STAGE is released, and a fix ships as a
  new version.
- `supersede-reason` and `gh-environment` are required. The workflow checks only that
  `gh-environment` is set, so the environment must have required reviewers.
- The caller's JFrog identity needs the `<project>-promotion` group from tf-artifactory, which grants
  the un-promote and the record write.
- A run that stops after the un-promote and before the record is stored leaves the swap unrecorded.
  A re-run finds the version already at the stage and does nothing.

To verify a stored record:

```bash
gh attestation verify record.json --bundle record.sigstore.json --repo <caller-org>/<caller-repo> \
  --predicate-type https://aerospike.com/schemas/supersede/v1 \
  --signer-workflow aerospike/shared-workflows/.github/workflows/reusable_promote-release-bundle.yaml
```

## Tests

```bash
bats .github/workflows/promote-release-bundle/tests/bats/
```
