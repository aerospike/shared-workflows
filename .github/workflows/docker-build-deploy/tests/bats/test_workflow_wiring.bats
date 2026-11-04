#!/usr/bin/env bats
#
# How the workflow's steps are wired together.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"

@test "no run: block expands an expression" {
    # Expansion happens before bash parses the script, so quoting does not
    # protect a caller value. Pass values through env: instead.
    run yq -r '.jobs[].steps[]? | select(.run) | select(.run | contains("${{")) | .name' "$WORKFLOW"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "the image is attested once, in merge" {
    # build is matrixed, so attesting there would attest each platform's image
    # separately instead of the manifest list consumers pull.
    run yq -r '.jobs | to_entries[]
        | {"job": .key, "n": ([.value.steps[]? | select((.uses // "") | test("attest-build-provenance"))] | length)}
        | select(.n > 0) | .job + "=" + (.n | tostring)' "$WORKFLOW"
    [ "$output" = "merge=1" ]
}

@test "artifact names, cache scope, and the merge glob use the invocation key" {
    local digest legmeta cache_from cache_to pattern overwrite
    digest="$(yq -r '.jobs.build.steps[] | select(.name == "Upload digest") | .with.name' "$WORKFLOW")"
    legmeta="$(yq -r '.jobs.build.steps[] | select(.name == "Upload leg metadata") | .with.name' "$WORKFLOW")"
    pattern="$(yq -r '.jobs.merge.steps[] | select(.name == "Download per-leg digests") | .with.pattern' "$WORKFLOW")"
    cache_from="$(yq -r '.jobs.build.steps[] | select(.with."cache-from") | .with."cache-from"' "$WORKFLOW")"
    cache_to="$(yq -r '.jobs.build.steps[] | select(.with."cache-to") | .with."cache-to"' "$WORKFLOW")"
    overwrite="$(yq -r '.jobs.build.steps[] | select(.name == "Upload digest" or .name == "Upload leg metadata") | .with.overwrite' "$WORKFLOW")"

    local key='${{ needs.parse-platforms.outputs.invocation-key }}'
    local platform='${{ matrix.sanitized }}'
    [ "$digest" = "digests-${key}--${platform}" ]
    [ "$legmeta" = "legmeta-${key}--${platform}" ]
    [ "$pattern" = "digests-${key}--*" ]
    [ "$cache_from" = "type=gha,scope=${key}--${platform}" ]
    [ "$cache_to" = "type=gha,mode=max,scope=${key}--${platform}" ]
    [ "$overwrite" = $'false\nfalse' ]
}
