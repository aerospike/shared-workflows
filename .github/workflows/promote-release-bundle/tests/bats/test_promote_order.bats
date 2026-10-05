#!/usr/bin/env bats

setup() {
    ENTRYPOINT="${BATS_TEST_DIRNAME}/../../entrypoint.sh"
    export JF_CALLS="${BATS_TEST_TMPDIR}/jf-calls.log"
    export JF_DATA="${BATS_TEST_TMPDIR}/data"
    export CURL_URL_LOG="${BATS_TEST_TMPDIR}/curl-urls"
    : >"$JF_CALLS"
    mkdir -p "$JF_DATA"
    jq -n '{promotions: [], total: 0}' >"${JF_DATA}/records.json"
    bundle_has app.deb app.rpm

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
url="${*: -1}"
echo "$url" >>"$CURL_URL_LOG"
if [[ -n ${CURL_FAILS-} ]]; then
    echo "curl: (22) HTTP 503" >&2
    exit 22
fi
path="${url%%\?*}"
case "${path#https://jfrog.test/lifecycle/api/v2/}" in
promotion/records/my-app/1.2.3) cat "${JF_DATA}/records.json" ;;
promotion/records/my-app/1.2.3/*) cat "${JF_DATA}/promotion-${path##*/}.json" ;;
release_bundle/records/my-app/1.2.3) cat "${JF_DATA}/bundle.json" ;;
*)
    echo "curl: (22) HTTP 404 for ${path}" >&2
    exit 22
    ;;
esac
STUB
    chmod +x "${BATS_TEST_TMPDIR}/bin/jf" "${BATS_TEST_TMPDIR}/bin/curl"
    export PATH="${BATS_TEST_TMPDIR}/bin:$PATH"
    cd "$BATS_TEST_TMPDIR" || exit 1
}

bundle_has() {
    jq -n '$ARGS.positional | {total_artifacts_count: length, artifacts: map({path: .})}' \
        --args "$@" >"${JF_DATA}/bundle.json"
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
        mapfile -t paths < <(jq -r '.artifacts[].path' "${JF_DATA}/bundle.json")
    fi
    jq -n --arg repo "test-${stage,,}-local" '$ARGS.positional | {artifacts: map({path: ($repo + "/" + .)})}' \
        --args "${paths[@]}" >"${JF_DATA}/promotion-${id}.json"
}

promote() {
    run bash "$ENTRYPOINT" --bundle-name my-app --version 1.2.3 --project test --target-stage "$@"
}

promoted_to() {
    grep -Fq "jf release-bundle-promote my-app 1.2.3 $1 --project=test" "$JF_CALLS"
}

@test "promotes to DEV with no prior promotion" {
    promote DEV
    [ "$status" -eq 0 ]
    promoted_to DEV
}

@test "promotes to TEST without DEV, which is optional" {
    promote TEST
    [ "$status" -eq 0 ]
    promoted_to TEST
}

@test "refuses STAGE until the version is at TEST" {
    promoted DEV
    promote STAGE
    [ "$status" -eq 1 ]
    [[ $output == *"::error::my-app/1.2.3 is not promoted to TEST, so it cannot be promoted to STAGE"* ]]
    [ ! -s "$JF_CALLS" ]
}

@test "promotes to PROD from STAGE without PREVIEW, which is optional" {
    promoted TEST
    promoted STAGE
    promote PROD
    [ "$status" -eq 0 ]
    promoted_to PROD
}

@test "refuses PREVIEW, INTERNAL and PROD until the version is at STAGE" {
    promoted TEST
    for stage in PREVIEW INTERNAL PROD; do
        promote "$stage"
        [ "$status" -eq 1 ]
        [[ $output == *"is not promoted to STAGE"* ]]
    done
    [ ! -s "$JF_CALLS" ]
}

@test "a TEST promotion that has not completed does not count toward STAGE" {
    for st in STARTED FAILED; do
        jq -n '{promotions: [], total: 0}' >"${JF_DATA}/records.json"
        promoted TEST "$st"
        promote STAGE
        [ "$status" -eq 1 ]
        [[ $output == *"is not promoted to TEST"* ]]
    done
    [ ! -s "$JF_CALLS" ]
}

@test "a TEST promotion of part of the bundle does not count toward STAGE" {
    promoted TEST COMPLETED app.deb
    promote STAGE
    [ "$status" -eq 1 ]
    [[ $output == *"1 artifacts of my-app/1.2.3 are not promoted to TEST, so it cannot be promoted to STAGE"* ]]
    [ ! -s "$JF_CALLS" ]
}

@test "TEST promotions that together hold the bundle count toward STAGE" {
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
    [[ $output == *"already promoted to TEST. Nothing to do."* ]]
    [ ! -s "$JF_CALLS" ]
}

@test "promoting the rest of a partly promoted version is not a no-op" {
    promoted TEST COMPLETED app.deb
    run bash "$ENTRYPOINT" --bundle-name my-app --version 1.2.3 --project test --target-stage TEST \
        --include-repos "test-rpm-test-local"
    [ "$status" -eq 0 ]
    grep -Fq -- "--include-repos=test-rpm-test-local" "$JF_CALLS"
}

@test "a failed promotion to the target is not a no-op" {
    promoted TEST FAILED
    promote TEST
    [ "$status" -eq 0 ]
    promoted_to TEST
}

@test "accepts a lower-case stage" {
    promoted TEST
    promote stage
    [ "$status" -eq 0 ]
    promoted_to STAGE
}

@test "rejects an unknown stage" {
    promote QA
    [ "$status" -eq 1 ]
    [[ $output == *"unknown target stage: QA"* ]]
}

@test "reads only the requested version's records" {
    promote TEST
    [ "$status" -eq 0 ]
    grep -Fq "/promotion/records/my-app/1.2.3?project=test&" "$CURL_URL_LOG"
}

@test "unreadable promotion records stop the promotion" {
    CURL_FAILS=1 promote TEST
    [ "$status" -eq 1 ]
    [[ $output == *"cannot promote without the promotion records for my-app/1.2.3"* ]]
    [ ! -s "$JF_CALLS" ]
}

@test "a records response without promotions stops the promotion" {
    echo '{"errors":[{"status":404}]}' >"${JF_DATA}/records.json"
    promote TEST
    [ "$status" -eq 1 ]
    [ ! -s "$JF_CALLS" ]
}

@test "an unreadable artifact list stops the promotion" {
    promoted TEST
    rm "${JF_DATA}/bundle.json"
    promote STAGE
    [ "$status" -eq 1 ]
    [[ $output == *"cannot promote without the artifact list of my-app/1.2.3"* ]]
    [ ! -s "$JF_CALLS" ]
}

@test "a truncated artifact list stops the promotion" {
    promoted TEST
    jq '.total_artifacts_count = 3' "${JF_DATA}/bundle.json" >"${JF_DATA}/bundle.tmp"
    mv "${JF_DATA}/bundle.tmp" "${JF_DATA}/bundle.json"
    promote STAGE
    [ "$status" -eq 1 ]
    [ ! -s "$JF_CALLS" ]
}

@test "passes include and exclude repos to jf" {
    run bash "$ENTRYPOINT" --bundle-name my-app --version 1.2.3 --project test --target-stage TEST \
        --include-repos "a-local;b-local" --exclude-repos "c-local"
    [ "$status" -eq 0 ]
    grep -Fq -- "--include-repos=a-local;b-local --exclude-repos=c-local" "$JF_CALLS"
}

@test "empty include and exclude repos are not passed to jf" {
    run bash "$ENTRYPOINT" --bundle-name my-app --version 1.2.3 --project test --target-stage TEST \
        --include-repos "" --exclude-repos ""
    [ "$status" -eq 0 ]
    run grep -F -e "--include-repos" -e "--exclude-repos" "$JF_CALLS"
    [ "$status" -eq 1 ]
}

@test "dry-run prints the promotion without running it" {
    run bash "$ENTRYPOINT" --bundle-name my-app --version 1.2.3 --project test --target-stage TEST --dry-run
    [ "$status" -eq 0 ]
    [[ $output == *"jf release-bundle-promote my-app 1.2.3 TEST --project=test"* ]]
    [[ $output == *"Would promote my-app/1.2.3 to TEST"* ]]
    [[ $output != *"Promoted"* ]]
    [ ! -s "$JF_CALLS" ]
}
