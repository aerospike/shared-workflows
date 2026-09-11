#!/usr/bin/env bats

setup() {
    GUARD="${BATS_TEST_DIRNAME}/../../guard-promoted-beyond.sh"
    export JF_RECORDS="${BATS_TEST_TMPDIR}/records.json"

    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    cat >"${BATS_TEST_TMPDIR}/bin/jf" <<'STUB'
#!/usr/bin/env bash
if [[ $1 == "config" && $2 == "export" ]]; then
    printf '%s' '{"url":"https://jfrog.test/","accessToken":"tkn"}' | base64 -w0
    exit 0
fi
exit 0
STUB
    cat >"${BATS_TEST_TMPDIR}/bin/curl" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
if [[ -n ${CURL_FAILS-} ]]; then
    echo "curl: (22) HTTP 503" >&2
    exit 22
fi
cat "$JF_RECORDS"
exit 0
STUB
    chmod +x "${BATS_TEST_TMPDIR}/bin/jf" "${BATS_TEST_TMPDIR}/bin/curl"
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

guard() {
    run bash "$GUARD" my-bundle "$1" test "test guard"
}

@test "refuses a version promoted beyond DEV" {
    records "1.0.0:DEV" "1.0.0:TEST"
    guard 1.0.0
    [ "$status" -eq 1 ]
    [[ $output == *"promoted beyond DEV"* ]]
    [[ $output == *"TEST"* ]]
}

@test "refuses at every stage past DEV" {
    for stage in TEST STAGE PREVIEW INTERNAL PROD; do
        records "1.0.0:$stage"
        guard 1.0.0
        [ "$status" -eq 1 ]
        [[ $output == *"promoted beyond DEV"* ]]
    done
}

@test "allows a version promoted only to DEV" {
    records "1.0.0:DEV"
    guard 1.0.0
    [ "$status" -eq 0 ]
    [[ $output == *"existing promotions: DEV"* ]]
}

@test "allows a version with no promotions" {
    records
    guard 1.0.0
    [ "$status" -eq 0 ]
    [[ $output == *"no existing promotions"* ]]
}

@test "ignores promotions belonging to another version" {
    records "9.9.9:PROD" "1.0.0:DEV"
    guard 1.0.0
    [ "$status" -eq 0 ]
}

@test "refuses when the records cannot be read" {
    records "1.0.0:DEV"
    CURL_FAILS=1 guard 1.0.0
    [ "$status" -eq 1 ]
    [[ $output == *"could not verify promotions"* ]]
}
