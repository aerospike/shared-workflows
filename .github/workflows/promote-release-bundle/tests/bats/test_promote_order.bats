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

@test "promotes to a stage only when the stage before it holds the version" {
    local row held target want stage
    local rows=(
        "- DEV promote"
        "- TEST promote"
        "DEV STAGE refuse"
        "TEST PREVIEW refuse"
        "TEST INTERNAL refuse"
        "TEST PROD refuse"
        "TEST,STAGE PROD promote"
    )
    for row in "${rows[@]}"; do
        setup_stubs
        read -r held target want <<<"$row"
        if [[ $held != - ]]; then
            IFS=, read -ra held <<<"$held"
            for stage in "${held[@]}"; do promoted "$stage"; done
        fi
        promote "$target"
        if [[ $want == promote ]]; then
            [ "$status" -eq 0 ]
            promoted_to "$target"
        else
            [ "$status" -eq 1 ]
            [[ $output == *"is not fully promoted to"* ]]
            [ ! -s "$JF_CALLS" ]
        fi
    done
}

@test "a stage holds the version only when completed promotions hold every artifact" {
    local row want rest promotions promotion paths
    local rows=(
        "refuse STARTED:app.deb,app.rpm"
        "refuse COMPLETED:app.deb"
        "promote COMPLETED:app.deb COMPLETED:app.rpm"
    )
    for row in "${rows[@]}"; do
        setup_stubs
        read -r want rest <<<"$row"
        read -ra promotions <<<"$rest"
        for promotion in "${promotions[@]}"; do
            IFS=, read -ra paths <<<"${promotion#*:}"
            promoted TEST "${promotion%%:*}" "${paths[@]}"
        done
        promote STAGE
        if [[ $want == promote ]]; then
            [ "$status" -eq 0 ]
            promoted_to STAGE
        else
            [ "$status" -eq 1 ]
            [ ! -s "$JF_CALLS" ]
        fi
    done
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
    [[ $output == *"cannot promote without the promotion records"* ]]
    [ ! -s "$JF_CALLS" ]
}

@test "passes include and exclude repos to jf only when set" {
    promote TEST --include-repos "a-local;b-local" --exclude-repos "c-local"
    grep -Fq -- "--include-repos=a-local;b-local --exclude-repos=c-local" "$JF_CALLS"
    : >"$JF_CALLS"
    promote TEST --include-repos "" --exclude-repos ""
    run grep -F -e "--include-repos" -e "--exclude-repos" "$JF_CALLS"
    [ "$status" -eq 1 ]
}
