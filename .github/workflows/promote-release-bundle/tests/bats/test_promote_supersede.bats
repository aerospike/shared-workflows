#!/usr/bin/env bats

setup() {
    ENTRYPOINT="${BATS_TEST_DIRNAME}/../../entrypoint.sh"
    export JF_CALLS="${BATS_TEST_TMPDIR}/jf-calls.log"
    export JF_RECORDS="${BATS_TEST_TMPDIR}/records.json"
    export JF_DEPLOYS="${BATS_TEST_TMPDIR}/deploys.log"
    : >"$JF_CALLS"
    : >"$JF_DEPLOYS"

    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    cat >"${BATS_TEST_TMPDIR}/bin/jf" <<'STUB'
#!/usr/bin/env bash
if [[ $1 == "config" && $2 == "export" ]]; then
    printf '%s' '{"url":"https://jfrog.test/","accessToken":"tkn"}' | base64 -w0
    exit 0
fi
echo "jf $*" >>"$JF_CALLS"
exit 0
STUB
    chmod +x "${BATS_TEST_TMPDIR}/bin/jf"

    cat >"${BATS_TEST_TMPDIR}/bin/curl" <<'STUB'
#!/usr/bin/env bash
# The curl config arrives on stdin.
cat >/dev/null
args=("$@")
method="" url="" payload=""
for ((i = 0; i < ${#args[@]}; i++)); do
    case "${args[i]}" in
    -X) method="${args[i + 1]}" ;;
    --data-binary) payload="${args[i + 1]#@}" ;;
    https://*) url="${args[i]}" ;;
    esac
done

if [[ $method == "PUT" ]]; then
    echo "PUT ${url}" >>"$JF_DEPLOYS"
    [[ -n $payload ]] && cat "$payload" >>"$JF_DEPLOYS"
    if [[ -n ${DEPLOY_FAILS-} ]]; then
        echo '{"errors":[{"status":403,"message":"needs DELETE permission"}]}'
        exit 22
    fi
    echo '{"repo":"release-evidence-local","path":"/rec.json"}'
    exit 0
fi

if [[ -n ${CURL_FAILS-} ]]; then
    echo "curl: (22) HTTP 503" >&2
    exit 22
fi
cat "$JF_RECORDS"
exit 0
STUB
    chmod +x "${BATS_TEST_TMPDIR}/bin/curl"
    export PATH="${BATS_TEST_TMPDIR}/bin:$PATH"
    cd "$BATS_TEST_TMPDIR" || exit 1
}

# Each entry is "version:stage".
records() {
    local entries=("$@") json="[]" e version stage
    for e in "${entries[@]}"; do
        version="${e%%:*}"
        stage="${e##*:}"
        json=$(echo "$json" | jq --arg v "$version" --arg s "$stage" \
            '. + [{release_bundle_version: $v, environment: $s, status: "COMPLETED"}]')
    done
    echo "{\"promotions\": $json}" >"$JF_RECORDS"
}

promote() {
    run bash "$ENTRYPOINT" --bundle-name my-app --project test --actor tester "$@"
}

@test "promotes into an empty stage" {
    records "1.2.3:DEV"
    promote --version 1.2.3 --target-stage TEST
    [ "$status" -eq 0 ]
    grep -q "release-bundle-promote my-app 1.2.3 TEST" "$JF_CALLS"
}

@test "refuses to overwrite an occupied stage and names the incumbent" {
    records "1.2.3:DEV" "1.2.3:TEST" "1.2.4:DEV"
    promote --version 1.2.4 --target-stage TEST
    [ "$status" -ne 0 ]
    [[ $output == *"already holds my-app/1.2.3"* ]]
    [[ $output == *"--supersede"* ]]
    ! grep -q "release-bundle-promote" "$JF_CALLS"
}

@test "supersede is not the default" {
    records "1.2.3:DEV" "1.2.3:TEST" "1.2.4:DEV"
    promote --version 1.2.4 --target-stage TEST
    [ "$status" -ne 0 ]
    ! grep -q "release-bundle-delete-local" "$JF_CALLS"
}

@test "supersede requires a reason" {
    records "1.2.3:DEV" "1.2.3:TEST" "1.2.4:DEV"
    promote --version 1.2.4 --target-stage TEST --supersede
    [ "$status" -ne 0 ]
    [[ $output == *"--supersede-reason is required"* ]]
}

@test "supersede removes the incumbent from the target stage only" {
    records "1.2.3:DEV" "1.2.3:TEST" "1.2.3:STAGE" "1.2.4:DEV" "1.2.4:TEST"
    promote --version 1.2.4 --target-stage STAGE --supersede --supersede-reason "failed integration"
    [ "$status" -eq 0 ]
    grep -q "release-bundle-delete-local my-app 1.2.3 STAGE" "$JF_CALLS"
    ! grep -q "release-bundle-delete-local my-app 1.2.3 TEST" "$JF_CALLS"
    grep -q "release-bundle-promote my-app 1.2.4 STAGE" "$JF_CALLS"
}

@test "supersede is refused at PREVIEW, INTERNAL and PROD" {
    for stage in PREVIEW INTERNAL; do
        records "1.2.3:STAGE" "1.2.3:$stage" "1.2.4:STAGE"
        promote --version 1.2.4 --target-stage "$stage" --supersede --supersede-reason "late fix"
        [ "$status" -ne 0 ]
        [[ $output == *"released stage"* ]]
        [[ $output == *"new version"* ]]
    done

    records "1.2.3:PREVIEW" "1.2.3:PROD" "1.2.4:PREVIEW"
    promote --version 1.2.4 --target-stage PROD --supersede --supersede-reason "late fix"
    [ "$status" -ne 0 ]
    [[ $output == *"released stage"* ]]
}

@test "refuses a promotion that skips a stage" {
    records "1.2.3:DEV"
    promote --version 1.2.3 --target-stage STAGE
    [ "$status" -ne 0 ]
    [[ $output == *"not promoted to TEST"* ]]
    ! grep -q "release-bundle-promote" "$JF_CALLS"
}

@test "the supersede record names both revisions and the stage" {
    records "1.2.3:DEV" "1.2.3:TEST" "1.2.4:DEV"
    promote --version 1.2.4 --target-stage TEST --supersede --supersede-reason "bad config default"
    [ "$status" -eq 0 ]

    local body
    body=$(grep -v '^PUT ' "$JF_DEPLOYS")
    [ "$(jq -r '.replaced | join(",")' <<<"$body")" = "1.2.3" ]
    [ "$(jq -r .replacedBy <<<"$body")" = "1.2.4" ]
    [ "$(jq -r .stage <<<"$body")" = "TEST" ]
    [ "$(jq -r .bundle <<<"$body")" = "my-app" ]
    [ "$(jq -r .project <<<"$body")" = "test" ]
    [ "$(jq -r .actor <<<"$body")" = "tester" ]
    [ "$(jq -r .reason <<<"$body")" = "bad config default" ]
    jq -e '.at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T")' <<<"$body"
}

@test "the record path carries project, bundle and stage" {
    records "1.2.3:DEV" "1.2.3:TEST" "1.2.4:DEV"
    promote --version 1.2.4 --target-stage TEST --supersede --supersede-reason "why"
    [ "$status" -eq 0 ]
    grep -qE "^PUT .*/artifactory/release-evidence-local/evidence/supersede/test/my-app/TEST/[0-9]+-1\.2\.4\.json$" \
        "$JF_DEPLOYS"
}

@test "one record covers every incumbent at the stage" {
    records "1.2.2:TEST" "1.2.3:DEV" "1.2.3:TEST" "1.2.4:DEV"
    promote --version 1.2.4 --target-stage TEST --supersede --supersede-reason "why"
    [ "$status" -eq 0 ]

    [ "$(grep -c '^PUT ' "$JF_DEPLOYS")" -eq 1 ]
    local body
    body=$(grep -v '^PUT ' "$JF_DEPLOYS")
    [ "$(jq -r '.replaced | sort | join(",")' <<<"$body")" = "1.2.2,1.2.3" ]
    [ "$(grep -c 'release-bundle-delete-local' "$JF_CALLS")" -eq 2 ]
}

@test "--evidence-repo redirects the record" {
    records "1.2.3:DEV" "1.2.3:TEST" "1.2.4:DEV"
    promote --version 1.2.4 --target-stage TEST --supersede --supersede-reason "why" \
        --evidence-repo release-evidence-scratch-local
    [ "$status" -eq 0 ]
    grep -q "/artifactory/release-evidence-scratch-local/evidence/" "$JF_DEPLOYS"
}

@test "the record is written before the incumbent is un-promoted" {
    records "1.2.3:DEV" "1.2.3:TEST" "1.2.4:DEV"
    promote --version 1.2.4 --target-stage TEST --supersede --supersede-reason "why"
    [ "$status" -eq 0 ]
    [ -s "$JF_DEPLOYS" ]
    grep -q "release-bundle-delete-local" "$JF_CALLS"
}

@test "a refused record write stops the supersede" {
    records "1.2.3:DEV" "1.2.3:TEST" "1.2.4:DEV"
    DEPLOY_FAILS=1 promote --version 1.2.4 --target-stage TEST --supersede --supersede-reason "why"
    [ "$status" -ne 0 ]
    [[ $output == *"could not write the supersede record"* ]]
    ! grep -q "release-bundle-delete-local" "$JF_CALLS"
    ! grep -q "release-bundle-promote" "$JF_CALLS"
}

@test "a crafted reason cannot inject record fields" {
    records "1.2.3:DEV" "1.2.3:TEST" "1.2.4:DEV"
    promote --version 1.2.4 --target-stage TEST --supersede \
        --supersede-reason 'broke","actor":"someone-else'
    [ "$status" -eq 0 ]

    local body
    body=$(grep -v '^PUT ' "$JF_DEPLOYS")
    [ "$(jq -r .actor <<<"$body")" = "tester" ]
    [ "$(jq -r .reason <<<"$body")" = 'broke","actor":"someone-else' ]
}

@test "promoting to a stage the version already occupies is a no-op" {
    records "1.2.3:DEV" "1.2.3:TEST"
    promote --version 1.2.3 --target-stage TEST
    [ "$status" -eq 0 ]
    [[ $output == *"already promoted"* ]]
    ! grep -q "release-bundle-promote" "$JF_CALLS"
}

@test "rejects an unknown stage" {
    records "1.2.3:DEV"
    promote --version 1.2.3 --target-stage QA
    [ "$status" -ne 0 ]
    [[ $output == *"unknown target stage"* ]]
}

@test "DEV needs no predecessor" {
    records
    promote --version 1.2.3 --target-stage DEV
    [ "$status" -eq 0 ]
    grep -q "release-bundle-promote my-app 1.2.3 DEV" "$JF_CALLS"
}

@test "an unreadable records response stops the promotion" {
    records "1.2.3:DEV"
    CURL_FAILS=1 promote --version 1.2.3 --target-stage TEST
    [ "$status" -ne 0 ]
    [[ $output == *"could not read promotion records"* ]]
    ! grep -q "release-bundle-promote" "$JF_CALLS"
}

@test "a records response without a promotions key stops the promotion" {
    echo '{"unexpected": true}' >"$JF_RECORDS"
    promote --version 1.2.3 --target-stage TEST
    [ "$status" -ne 0 ]
    [[ $output == *"unexpected promotion records response"* ]]
    ! grep -q "release-bundle-promote" "$JF_CALLS"
}
