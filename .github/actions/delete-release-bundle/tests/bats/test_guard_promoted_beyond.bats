#!/usr/bin/env bats

setup() {
    GUARD="${BATS_TEST_DIRNAME}/../../guard-promoted-beyond.sh"
    export JF_RECORDS="${BATS_TEST_TMPDIR}/records"
    export CURL_URL_LOG="${BATS_TEST_TMPDIR}/curl-urls"
    mkdir -p "$JF_RECORDS"

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
url="${*: -1}"
echo "$url" >>"$CURL_URL_LOG"
if [[ -n ${CURL_FAILS-} ]]; then
    echo "curl: (22) HTTP 503" >&2
    exit 22
fi
path="${url%%\?*}"
cat "${JF_RECORDS}/${path##*/}.json"
STUB
    chmod +x "${BATS_TEST_TMPDIR}/bin/jf" "${BATS_TEST_TMPDIR}/bin/curl"
    export PATH="${BATS_TEST_TMPDIR}/bin:$PATH"
    cd "$BATS_TEST_TMPDIR" || exit 1
}

# records VERSION [STAGE[:STATUS]]... ; STATUS defaults to COMPLETED.
records() {
    local version="$1" json="[]" e stage status
    shift
    for e in "$@"; do
        stage="${e%%:*}"
        status=COMPLETED
        [[ $e == *:* ]] && status="${e#*:}"
        json=$(jq --arg v "$version" --arg s "$stage" --arg st "$status" \
            '. + [{release_bundle_version: $v, environment: $s, status: $st}]' <<<"$json")
    done
    jq -n --argjson p "$json" '{promotions: $p, total: ($p | length)}' >"${JF_RECORDS}/${version}.json"
}

guard() {
    run bash "$GUARD" my-bundle "$1" test "test guard"
}

@test "refuses a version promoted beyond DEV" {
    records 1.0.0 DEV TEST
    guard 1.0.0
    [ "$status" -eq 1 ]
    [[ $output == *"beyond DEV (TEST)"* ]]
}

@test "refuses at every stage past DEV" {
    for stage in TEST STAGE PREVIEW INTERNAL PROD; do
        records 1.0.0 "$stage"
        guard 1.0.0
        [ "$status" -eq 1 ]
        [[ $output == *"beyond DEV ($stage)"* ]]
    done
}

@test "refuses a stage it does not know" {
    for stage in prod CERT; do
        records 1.0.0 "$stage"
        guard 1.0.0
        [ "$status" -eq 1 ]
        [[ $output == *"beyond DEV ($stage)"* ]]
    done
}

@test "refuses a promotion past DEV that has not finished" {
    for st in STARTED PENDING; do
        records 1.0.0 "TEST:$st"
        guard 1.0.0
        [ "$status" -eq 1 ]
        [[ $output == *"beyond DEV (TEST)"* ]]
    done
}

@test "allows a version whose promotion past DEV failed" {
    records 1.0.0 DEV TEST:FAILED
    guard 1.0.0
    [ "$status" -eq 0 ]
    [[ $output == *"existing promotions: DEV."* ]]
}

@test "allows a version promoted only to DEV" {
    records 1.0.0 DEV
    guard 1.0.0
    [ "$status" -eq 0 ]
    [[ $output == *"existing promotions: DEV."* ]]
}

@test "allows a version with no promotions" {
    records 1.0.0
    guard 1.0.0
    [ "$status" -eq 0 ]
    [[ $output == *"no existing promotions"* ]]
}

@test "reads only the requested version's records" {
    records 9.9.9 PROD
    records 1.0.0 DEV
    guard 1.0.0
    [ "$status" -eq 0 ]
    grep -Fq "/promotion/records/my-bundle/1.0.0?project=test&" "$CURL_URL_LOG"
}

@test "URL-encodes the version" {
    records "1.0.0%2B42" PROD
    guard "1.0.0+42"
    [ "$status" -eq 1 ]
    grep -Fq "/my-bundle/1.0.0%2B42?" "$CURL_URL_LOG"
}

@test "refuses when the records cannot be read" {
    records 1.0.0 DEV
    CURL_FAILS=1 guard 1.0.0
    [ "$status" -eq 1 ]
    [[ $output == *"could not verify promotions"* ]]
}

@test "refuses when the response has more records than it returned" {
    jq -n '{total: 2, promotions: [{environment: "DEV", status: "COMPLETED"}]}' >"${JF_RECORDS}/1.0.0.json"
    guard 1.0.0
    [ "$status" -eq 1 ]
    [[ $output == *"could not verify promotions"* ]]
}

@test "refuses when a record has no stage or status" {
    jq -n '{total: 1, promotions: [{target_environment: "PROD", status: "COMPLETED"}]}' >"${JF_RECORDS}/1.0.0.json"
    guard 1.0.0
    [ "$status" -eq 1 ]
    jq -n '{total: 1, promotions: [{environment: "PROD"}]}' >"${JF_RECORDS}/1.0.0.json"
    guard 1.0.0
    [ "$status" -eq 1 ]
}

@test "keeps the token out of xtrace" {
    records 1.0.0 DEV
    run bash -x "$GUARD" my-bundle 1.0.0 test "test guard"
    [ "$status" -eq 0 ]
    [[ $output != *tkn* ]]
    [[ $output != *"$(printf '%s' '{"url":"https://jfrog.test/","accessToken":"tkn"}' | base64)"* ]]
}
