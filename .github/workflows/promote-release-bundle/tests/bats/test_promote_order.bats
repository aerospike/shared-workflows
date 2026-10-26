#!/usr/bin/env bats

load helpers

setup() {
    setup_stubs
}

# promoted STAGE [STATUS [PATH...]]. PATH defaults to every artifact in the bundle.
promoted() {
    local stage="$1" status="${2:-COMPLETED}" id paths
    shift
    (($#)) && shift
    id=$(jq '.promotions | length + 1000' "${JF_DATA}/records.json")
    jq --arg s "$stage" --arg st "$status" --argjson id "$id" \
        '.promotions += [{environment: $s, status: $st, created_millis: $id}] | .total = (.promotions | length)' \
        "${JF_DATA}/records.json" >"${JF_DATA}/records.tmp"
    mv "${JF_DATA}/records.tmp" "${JF_DATA}/records.json"
    if (($#)); then
        paths=("$@")
    else
        mapfile -t paths < <(jq -r '.artifacts[].path' "${JF_DATA}/bundle-1.2.3.json")
    fi
    jq -n --arg repo "test-${stage,,}-local" '$ARGS.positional | {artifacts: map({path: ($repo + "/" + .)})}' \
        --args "${paths[@]}" >"${JF_DATA}/promotion-${id}.json"
}

@test "promotes to DEV or TEST with no prior promotion" {
    for stage in DEV TEST; do
        promote "$stage"
        [ "$status" -eq 0 ]
        promoted_to "$stage"
    done
}

@test "refuses STAGE until the version is at TEST" {
    promoted DEV
    promote STAGE
    [ "$status" -eq 1 ]
    [[ $output == *"::error::my-app/1.2.3 is not fully promoted to TEST, so it cannot be promoted to STAGE"* ]]
    [ ! -s "$JF_CALLS" ]
}

@test "refuses PREVIEW, INTERNAL and PROD until the version is at STAGE" {
    promoted TEST
    for stage in PREVIEW INTERNAL PROD; do
        promote "$stage"
        [ "$status" -eq 1 ]
    done
    [ ! -s "$JF_CALLS" ]
}

@test "promotes to PROD from STAGE without PREVIEW" {
    promoted TEST
    promoted STAGE
    promote PROD
    [ "$status" -eq 0 ]
    promoted_to PROD
}

@test "a TEST promotion that has not completed does not count" {
    promoted TEST STARTED
    promote STAGE
    [ "$status" -eq 1 ]
}

@test "a TEST promotion of part of the bundle does not count" {
    promoted TEST COMPLETED app.deb
    promote STAGE
    [ "$status" -eq 1 ]
}

@test "TEST promotions that together hold the bundle count" {
    promoted TEST COMPLETED app.deb
    promoted TEST COMPLETED app.rpm
    promote STAGE
    [ "$status" -eq 0 ]
    promoted_to STAGE
}

@test "promoting to a stage that holds the whole version is a no-op" {
    promoted TEST
    promote TEST
    [ "$status" -eq 0 ]
    [ ! -s "$JF_CALLS" ]
}

@test "unreadable promotion records stop the promotion" {
    CURL_FAILS=1 promote TEST
    [ "$status" -eq 1 ]
    [ ! -s "$JF_CALLS" ]
}

@test "a truncated artifact list stops the promotion" {
    promoted TEST
    jq '.total_artifacts_count = 3' "${JF_DATA}/bundle-1.2.3.json" >"${JF_DATA}/bundle-1.2.3.tmp"
    mv "${JF_DATA}/bundle-1.2.3.tmp" "${JF_DATA}/bundle-1.2.3.json"
    promote STAGE
    [ "$status" -eq 1 ]
}

@test "passes include and exclude repos to jf only when set" {
    promote TEST --include-repos "a-local;b-local" --exclude-repos "c-local"
    grep -Fq -- "--include-repos=a-local;b-local --exclude-repos=c-local" "$JF_CALLS"
    : >"$JF_CALLS"
    promote TEST --include-repos "" --exclude-repos ""
    run grep -F -e "--include-repos" -e "--exclude-repos" "$JF_CALLS"
    [ "$status" -eq 1 ]
}

@test "dry-run prints the promotion without running it" {
    promote TEST --dry-run
    [ "$status" -eq 0 ]
    [[ $output == *"Would promote my-app/1.2.3 to TEST"* ]]
    [ ! -s "$JF_CALLS" ]
}
