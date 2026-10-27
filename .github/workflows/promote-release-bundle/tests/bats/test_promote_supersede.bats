#!/usr/bin/env bats

load helpers

setup() {
    setup_stubs
    export GITHUB_TRIGGERING_ACTOR=octocat GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=aerospike/app \
        GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=2
}

# at_stage VERSION STAGE [STATUS]
at_stage() {
    jq --arg v "$1" --arg s "$2" --arg st "${3:-COMPLETED}" \
        '.promotions += [{release_bundle_version: $v, environment: $s, status: $st}] | .total = (.promotions | length)' \
        "${JF_DATA}/stage-records.json" >"${JF_DATA}/stage-records.tmp"
    mv "${JF_DATA}/stage-records.tmp" "${JF_DATA}/stage-records.json"
}

supersede() {
    promote TEST --supersede "rebuilt with the CVE fix" "$@"
}

output_value() {
    sed -n "s/^$1=//p" "$GITHUB_OUTPUT"
}

@test "un-promotes the completed version sharing a path, promotes, then writes the record and summary" {
    bundle_has 1.2.2 app.deb
    bundle_has 1.2.1 app.deb
    bundle_has 1.0.0 old.deb
    at_stage 1.2.2 TEST
    at_stage 1.2.1 TEST FAILED
    at_stage 1.0.0 TEST
    promote TEST --supersede $'CVE fix | rebuilt\nwith patch'
    [ "$status" -eq 0 ]
    [ "$(cat "$JF_CALLS")" = "jf release-bundle-delete-local my-app 1.2.2 TEST --project=test --quiet --sync
jf release-bundle-promote my-app 1.2.3 TEST --project=test" ]
    jq -e '.replaced == ["1.2.2"] and .replacedBy == "1.2.3" and .stage == "TEST" and .actor == "octocat"
        and .reason == "CVE fix | rebuilt\nwith patch"
        and .run == "https://github.com/aerospike/app/actions/runs/42/attempts/2"' "$(output_value record-file)"
    [[ $(output_value record-path) == release-evidence-local/evidence/supersede/test/my-app/TEST/*-1.2.3.json ]]
    grep -Fxq '### Superseded at TEST' "$GITHUB_STEP_SUMMARY"
    grep -Fxq '| Replaced | 1.2.2 |' "$GITHUB_STEP_SUMMARY"
    grep -Fxq '| Reason | CVE fix \| rebuilt with patch |' "$GITHUB_STEP_SUMMARY"
}

@test "a failed promote re-promotes the incumbent and writes no record" {
    bundle_has 1.2.2 app.deb
    at_stage 1.2.2 TEST
    JF_FAILS="release-bundle-promote my-app 1.2.3" supersede
    [ "$status" -eq 1 ]
    promoted_to TEST 1.2.2
    [ ! -s "$GITHUB_OUTPUT" ]
    [ ! -s "$GITHUB_STEP_SUMMARY" ]
}

@test "a failed un-promote re-promotes the incumbents already un-promoted" {
    bundle_has 1.2.1 app.deb
    bundle_has 1.2.2 app.rpm
    at_stage 1.2.1 TEST
    at_stage 1.2.2 TEST
    JF_FAILS="release-bundle-delete-local my-app 1.2.2" supersede
    [ "$status" -eq 1 ]
    promoted_to TEST 1.2.1
    run promoted_to TEST 1.2.3
    [ "$status" -eq 1 ]
}

@test "with nothing to replace, a supersede is a plain promote with no record" {
    bundle_has 1.0.0 old.deb
    at_stage 1.0.0 TEST
    supersede
    [ "$status" -eq 0 ]
    [ "$(cat "$JF_CALLS")" = "jf release-bundle-promote my-app 1.2.3 TEST --project=test" ]
    [ ! -s "$GITHUB_OUTPUT" ]
}

@test "refuses a supersede at PREVIEW, INTERNAL and PROD" {
    for stage in PREVIEW INTERNAL PROD; do
        promote "$stage" --supersede "rebuilt"
        [ "$status" -eq 1 ]
        [[ $output == *"a version at ${stage} cannot be superseded"* ]]
    done
    [ ! -s "$JF_CALLS" ]
}

@test "refuses a supersede without a reason" {
    promote TEST --supersede ""
    [ "$status" -eq 1 ]
    [[ $output == *"--supersede requires a reason"* ]]
    [ ! -s "$JF_CALLS" ]
}

@test "truncated promotion records stop the supersede" {
    bundle_has 1.2.2 app.deb
    at_stage 1.2.2 TEST
    jq '.total = 1001' "${JF_DATA}/stage-records.json" >"${JF_DATA}/stage-records.tmp"
    mv "${JF_DATA}/stage-records.tmp" "${JF_DATA}/stage-records.json"
    supersede
    [ "$status" -eq 1 ]
    [[ $output == *"truncated promotion records"* ]]
    [ ! -s "$JF_CALLS" ]
}

@test "dry-run prints the swap and writes no record" {
    bundle_has 1.2.2 app.deb
    at_stage 1.2.2 TEST
    supersede --dry-run
    [ "$status" -eq 0 ]
    [[ $output == *"Would promote my-app/1.2.3 to TEST in place of 1.2.2"* ]]
    [ ! -s "$JF_CALLS" ]
    [ ! -s "$GITHUB_OUTPUT" ]
    [ ! -s "$GITHUB_STEP_SUMMARY" ]
}
