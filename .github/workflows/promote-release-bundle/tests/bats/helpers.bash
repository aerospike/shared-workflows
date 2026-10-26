#!/usr/bin/env bash

# Stubs jf and curl for the entrypoint. The version under test is my-app/1.2.3 in project test.
setup_stubs() {
        ENTRYPOINT="${BATS_TEST_DIRNAME}/../../entrypoint.sh"
        export JF_CALLS="${BATS_TEST_TMPDIR}/jf-calls.log"
        export JF_DATA="${BATS_TEST_TMPDIR}/data"
        export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/output"
        export RUNNER_TEMP="$BATS_TEST_TMPDIR"
        : >"$JF_CALLS"
        : >"$GITHUB_OUTPUT"
        mkdir -p "$JF_DATA"
        jq -n '{promotions: [], total: 0}' >"${JF_DATA}/records.json"
        jq -n '{promotions: [], total: 0}' >"${JF_DATA}/stage-records.json"
        bundle_has 1.2.3 app.deb app.rpm

        mkdir -p "${BATS_TEST_TMPDIR}/bin"
        cat >"${BATS_TEST_TMPDIR}/bin/jf" <<'STUB'
#!/usr/bin/env bash
if [[ $1 == "config" && $2 == "export" ]]; then
    printf '%s' '{"url":"https://jfrog.test/","accessToken":"tkn"}' | base64 -w0
    exit 0
fi
echo "jf $*" >>"$JF_CALLS"
[[ -z ${JF_FAILS-} || "jf $*" != *"$JF_FAILS"* ]] || exit 1
STUB
        cat >"${BATS_TEST_TMPDIR}/bin/curl" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
[[ -z ${CURL_FAILS-} ]] || exit 22
path="${*: -1}"
path="${path%%\?*}"
case "${path#https://jfrog.test/lifecycle/api/v2/}" in
promotion/records/my-app) cat "${JF_DATA}/stage-records.json" ;;
promotion/records/my-app/1.2.3) cat "${JF_DATA}/records.json" ;;
promotion/records/my-app/1.2.3/*) cat "${JF_DATA}/promotion-${path##*/}.json" ;;
release_bundle/records/my-app/*) cat "${JF_DATA}/bundle-${path##*/}.json" ;;
*) exit 22 ;;
esac
STUB
        chmod +x "${BATS_TEST_TMPDIR}/bin/jf" "${BATS_TEST_TMPDIR}/bin/curl"
        export PATH="${BATS_TEST_TMPDIR}/bin:$PATH"
        cd "$BATS_TEST_TMPDIR" || exit 1
}

# bundle_has VERSION PATH...
bundle_has() {
        local version="$1"
        shift
        jq -n '$ARGS.positional | {total_artifacts_count: length, artifacts: map({path: .})}' \
                --args "$@" >"${JF_DATA}/bundle-${version}.json"
}

promote() {
        run bash "$ENTRYPOINT" --bundle-name my-app --version 1.2.3 --project test --target-stage "$@"
}

promoted_to() {
        grep -Fq "jf release-bundle-promote my-app ${2:-1.2.3} $1 --project=test" "$JF_CALLS"
}
