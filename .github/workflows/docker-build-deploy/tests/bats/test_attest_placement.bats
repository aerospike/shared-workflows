#!/usr/bin/env bats
#
# Where the build-provenance attestation runs.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"

@test "the image is attested exactly once" {
    local n
    n="$(yq -r '[.jobs[] | .steps[]?
        | select((.uses // "") | test("attest-build-provenance"))] | length' "$WORKFLOW")"
    [ "$n" = "1" ]
}

@test "attestation belongs to merge, not to a build leg" {
    # build is matrixed, so attesting there would attest each platform's image
    # separately instead of the manifest list consumers actually pull.
    local job
    job="$(yq -r '.jobs | to_entries[]
        | select(.value.steps[]?.uses // "" | test("attest-build-provenance"))
        | .key' "$WORKFLOW")"
    [ "$job" = "merge" ]
}
