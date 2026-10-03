#!/usr/bin/env bats

setup() {
    ENTRYPOINT="${BATS_TEST_DIRNAME}/../../entrypoint.sh"
    export JF_CALLS="${BATS_TEST_TMPDIR}/jf-calls.log"
    export JF_RECORDS="${BATS_TEST_TMPDIR}/records.json"
    : >"$JF_CALLS"

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
    cat >"${BATS_TEST_TMPDIR}/bin/curl" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
if [[ -n ${CURL_FAILS-} ]]; then
    echo "curl: (22) HTTP 503" >&2
    exit 22
fi
cat "$JF_RECORDS"
STUB
    chmod +x "${BATS_TEST_TMPDIR}/bin/jf" "${BATS_TEST_TMPDIR}/bin/curl"
    export PATH="${BATS_TEST_TMPDIR}/bin:$PATH"
    cd "$BATS_TEST_TMPDIR" || exit 1
}

# Each entry is "version:stage".
records() {
    local entries=("$@") json="[]" e
    for e in "${entries[@]}"; do
        json=$(jq --arg v "${e%%:*}" --arg s "${e##*:}" \
            '. + [{release_bundle_version: $v, environment: $s, status: "COMPLETED"}]' <<<"$json")
    done
    echo "{\"promotions\": $json}" >"$JF_RECORDS"
}

promote() {
    run bash "$ENTRYPOINT" --bundle-name my-app --version 1.2.3 --project test --target-stage "$@"
}

promoted_to() {
    grep -Fq "jf release-bundle-promote my-app 1.2.3 $1 --project=test" "$JF_CALLS"
}

@test "promotes to DEV with no prior promotion" {
    records
    promote DEV
    [ "$status" -eq 0 ]
    promoted_to DEV
}

@test "promotes to TEST without DEV, which is optional" {
    records
    promote TEST
    [ "$status" -eq 0 ]
    promoted_to TEST
}

@test "refuses STAGE until the version is at TEST" {
    records "1.2.3:DEV"
    promote STAGE
    [ "$status" -eq 1 ]
    [[ $output == *"my-app/1.2.3 is not promoted to TEST, so it cannot be promoted to STAGE"* ]]
    [ ! -s "$JF_CALLS" ]
}

@test "promotes to PROD from STAGE without PREVIEW, which is optional" {
    records "1.2.3:TEST" "1.2.3:STAGE"
    promote PROD
    [ "$status" -eq 0 ]
    promoted_to PROD
}

@test "refuses PREVIEW, INTERNAL and PROD until the version is at STAGE" {
    records "1.2.3:TEST"
    for stage in PREVIEW INTERNAL PROD; do
        promote "$stage"
        [ "$status" -eq 1 ]
        [[ $output == *"is not promoted to STAGE"* ]]
    done
    [ ! -s "$JF_CALLS" ]
}

@test "another version at the target stage does not stop the promotion" {
    records "1.2.2:PROD" "1.2.3:STAGE"
    promote PROD
    [ "$status" -eq 0 ]
    promoted_to PROD
}

@test "a promotion of another version does not count toward the required stage" {
    records "1.2.2:STAGE"
    promote PROD
    [ "$status" -eq 1 ]
    [[ $output == *"is not promoted to STAGE"* ]]
}

@test "promoting to a stage the version is already at is a no-op" {
    records "1.2.3:TEST"
    promote TEST
    [ "$status" -eq 0 ]
    [[ $output == *"already promoted to TEST. Nothing to do."* ]]
    [ ! -s "$JF_CALLS" ]
}

@test "accepts a lower-case stage" {
    records "1.2.3:TEST"
    promote stage
    [ "$status" -eq 0 ]
    promoted_to STAGE
}

@test "rejects an unknown stage" {
    records
    promote QA
    [ "$status" -eq 1 ]
    [[ $output == *"unknown target stage: QA"* ]]
}

@test "unreadable promotion records stop the promotion" {
    records
    CURL_FAILS=1 promote TEST
    [ "$status" -eq 1 ]
    [[ $output == *"cannot promote without the promotion records for my-app"* ]]
    [ ! -s "$JF_CALLS" ]
}

@test "a records response without promotions stops the promotion" {
    echo '{"errors":[{"status":404}]}' >"$JF_RECORDS"
    promote TEST
    [ "$status" -eq 1 ]
    [ ! -s "$JF_CALLS" ]
}

@test "passes include and exclude repos to jf" {
    records
    run bash "$ENTRYPOINT" --bundle-name my-app --version 1.2.3 --project test --target-stage TEST \
        --include-repos "a-local;b-local" --exclude-repos "c-local"
    [ "$status" -eq 0 ]
    grep -Fq -- "--include-repos=a-local;b-local --exclude-repos=c-local" "$JF_CALLS"
}

@test "dry-run prints the promotion without running it" {
    records
    run bash "$ENTRYPOINT" --bundle-name my-app --version 1.2.3 --project test --target-stage TEST --dry-run
    [ "$status" -eq 0 ]
    [[ $output == *"jf release-bundle-promote my-app 1.2.3 TEST --project=test"* ]]
    [ ! -s "$JF_CALLS" ]
}
