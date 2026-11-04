#!/usr/bin/env bats
#
# Per-leg artifact names and the Actions cache scope.
#
# Two calls in one run that share image-name (full and slim) must not share
# digest artifacts. The download glob is bash-compatible with the minimatch
# glob actions/download-artifact uses: `*` is only the platform, and `--`
# before it is literal.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"

setup_file() {
    export SCRIPT_UNDER_TEST="${BATS_FILE_TMPDIR}/parse.sh"
    yq -r '.jobs."parse-platforms".steps[] | select(.name == "Parse platforms into matrix") | .run' \
        "$WORKFLOW" > "$SCRIPT_UNDER_TEST"
}

setup() {
    export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
}

# run_parse <image> <build> <app-version> [platforms]
run_parse() {
    : > "$GITHUB_OUTPUT"
    IMAGE_NAME="$1" \
        BUILD_NAME="$2" \
        APP_VERSION="$3" \
        PLATFORMS="${4:-linux/amd64,linux/arm64}" \
        run bash "$SCRIPT_UNDER_TEST" </dev/null
}

invocation_key() {
    grep '^invocation-key=' "$GITHUB_OUTPUT" | cut -d= -f2-
}

@test "the key uses the tag form of app-version and only the separator is a double dash" {
    local image build version want
    while IFS=$'\t' read -r image build version want; do
        run_parse "$image" "$build" "$version"
        [ "$status" -eq 0 ]
        if [ "$(invocation_key)" != "$want" ]; then
            echo "got $(invocation_key), want $want"
            return 1
        fi
    done <<'CASES'
img	build	v1.2.3+abc	img--build--1.2.3-abc
foo--bar/baz:qux	build--name	1.0.0++meta	foo-bar-baz-qux--build-name--1.0.0-meta
img	Test Docker Build-Deploy Workflow	1.2.9	img--Test-Docker-Build-Deploy-Workflow--1.2.9
CASES
}

@test "each call's digest glob matches only its own artifacts" {
    local -a keys=()
    local image build version
    while read -r image build version; do
        run_parse "$image" "$build" "$version"
        [ "$status" -eq 0 ]
        keys+=("$(invocation_key)")
    done <<'CASES'
aerospike-graph-service aerospike-graph-service 3.3.2
aerospike-graph-service aerospike-graph-service-slim 3.3.2-slim
test-image shared-build 1.2.3
test-image-ctx shared-build 1.2.3
img build 3.3.2
img build 3.3.2-slim
img build-slim 3.3.2
CASES

    local i j
    for i in "${!keys[@]}"; do
        for j in "${!keys[@]}"; do
            if [[ "digests-${keys[j]}--linux-amd64" == digests-"${keys[i]}"--* ]]; then
                [ "$i" -eq "$j" ] || { echo "digests-${keys[i]}--* matched ${keys[j]}"; return 1; }
            else
                [ "$i" -ne "$j" ] || { echo "digests-${keys[i]}--* missed its own artifact"; return 1; }
            fi
        done
    done
}

@test "platforms are sanitized into the matrix" {
    run_parse img build 1.0.0 'linux/amd64,linux/arm64,linux/foo--bar'
    [ "$status" -eq 0 ]
    local sans
    sans="$(grep '^matrix=' "$GITHUB_OUTPUT" | cut -d= -f2- | jq -r '[.[].sanitized] | join(" ")')"
    [ "$sans" = "linux-amd64 linux-arm64 linux-foo-bar" ]
}

@test "fails when the inputs cannot form a unique key" {
    run_parse '' build 1.0.0
    [ "$status" -ne 0 ]
    run_parse img build v
    [ "$status" -ne 0 ]
    run_parse img build 1.0.0 'linux/amd64,linux-amd64'
    [ "$status" -ne 0 ]
}
