#!/usr/bin/env bats
#
# Per-leg artifact names and the Actions cache scope.
#
# Two calls in one run that share image-name (full and slim) must not share
# digest artifacts. The download glob is bash-compatible with the minimatch
# glob actions/download-artifact uses: `*` is only the platform, and `--`
# before it is literal.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"
TEST_WORKFLOW="${BATS_TEST_DIRNAME}/../../../test_docker-build-deploy-workflow.yaml"
STEP_NAME="Parse platforms into matrix"

setup_file() {
    export SCRIPT_UNDER_TEST="${BATS_FILE_TMPDIR}/parse.sh"
    yq -r ".jobs.\"parse-platforms\".steps[] | select(.name == \"$STEP_NAME\") | .run" \
        "$WORKFLOW" > "$SCRIPT_UNDER_TEST"

    export VERSION_STEP="${BATS_FILE_TMPDIR}/version.sh"
    yq -r '.jobs.verify.steps[] | select(.name == "Artifact version segment") | .run' \
        "$TEST_WORKFLOW" > "$VERSION_STEP"
}

setup() {
    export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
    : > "$GITHUB_OUTPUT"
}

# run_parse <image> <build> <app-version> [platforms]
run_parse() {
    : > "$GITHUB_OUTPUT"
    IMAGE_NAME="$1" \
        BUILD_NAME="$2" \
        APP_VERSION="$3" \
        PLATFORMS="${4:-linux/amd64,linux/arm64}" \
        run bash "$SCRIPT_UNDER_TEST"
}

invocation_key() {
    grep '^invocation-key=' "$GITHUB_OUTPUT" | cut -d= -f2-
}

# True when download-artifact's glob would select this artifact name.
glob_matches() {
    local name="$1" pattern="$2"
    # The unquoted right-hand side is the glob, on purpose.
    # shellcheck disable=SC2053
    [[ "$name" == $pattern ]]
}

separator_count() {
    local rest="$1" n=0
    while [[ "$rest" == *"--"* ]]; do
        rest="${rest#*--}"
        n=$((n + 1))
    done
    printf '%s' "$n"
}

@test "the step this suite tests still exists in the workflow" {
    [ -s "$SCRIPT_UNDER_TEST" ]
}

@test "full and slim graph builds do not share a digest glob" {
    run_parse aerospike-graph-service aerospike-graph-service 3.3.2
    [ "$status" -eq 0 ]
    local full
    full="$(invocation_key)"
    [ "$full" = "aerospike-graph-service--aerospike-graph-service--3.3.2" ]

    run_parse aerospike-graph-service aerospike-graph-service-slim 3.3.2-slim
    [ "$status" -eq 0 ]
    local slim
    slim="$(invocation_key)"
    [ "$slim" = "aerospike-graph-service--aerospike-graph-service-slim--3.3.2-slim" ]

    local plat artifact
    for plat in linux-amd64 linux-arm64; do
        artifact="digests-${slim}--${plat}"
        if glob_matches "$artifact" "digests-${full}--*"; then
            echo "full pattern matched slim artifact: $artifact"
            return 1
        fi
        glob_matches "digests-${full}--${plat}" "digests-${full}--*"
        glob_matches "legmeta-${slim}--${plat}" "legmeta-${slim}--*"
        if glob_matches "legmeta-${slim}--${plat}" "legmeta-${full}--*"; then
            echo "full legmeta pattern matched slim artifact"
            return 1
        fi
    done
}

@test "an image-name does not match another that starts with it" {
    run_parse test-image shared-build 1.2.3
    [ "$status" -eq 0 ]
    local short
    short="$(invocation_key)"

    run_parse test-image-ctx shared-build 1.2.3
    [ "$status" -eq 0 ]
    local long
    long="$(invocation_key)"

    if glob_matches "digests-${long}--linux-amd64" "digests-${short}--*"; then
        echo "test-image pattern matched test-image-ctx"
        return 1
    fi
    glob_matches "digests-${short}--linux-amd64" "digests-${short}--*"
}

@test "a build name does not match another that starts with it" {
    run_parse img aerospike-graph-service 3.3.2
    [ "$status" -eq 0 ]
    local full
    full="$(invocation_key)"

    run_parse img aerospike-graph-service-slim 3.3.2
    [ "$status" -eq 0 ]
    local slim
    slim="$(invocation_key)"

    if glob_matches "digests-${slim}--linux-arm64" "digests-${full}--*"; then
        echo "build-name pattern matched the longer build name"
        return 1
    fi
}

@test "an app-version does not match another that starts with it" {
    run_parse img shared-build 3.3.2
    [ "$status" -eq 0 ]
    local full
    full="$(invocation_key)"

    run_parse img shared-build 3.3.2-slim
    [ "$status" -eq 0 ]
    local slim
    slim="$(invocation_key)"

    if glob_matches "digests-${slim}--linux-amd64" "digests-${full}--*"; then
        echo "3.3.2 pattern matched 3.3.2-slim"
        return 1
    fi
}

@test "app-version uses the tag form before sanitizing" {
    run_parse img build 'v1.2.3+abc'
    [ "$status" -eq 0 ]
    [ "$(invocation_key)" = "img--build--1.2.3-abc" ]
}

@test "only the separator is a double dash" {
    run_parse 'foo--bar/baz:qux' 'build--name' '1.0.0++meta'
    [ "$status" -eq 0 ]
    local key
    key="$(invocation_key)"
    [ "$key" = "foo-bar-baz-qux--build-name--1.0.0-meta" ]
    [ "$(separator_count "$key")" -eq 2 ]
}

@test "a workflow name with spaces is a single segment" {
    run_parse img 'Test Docker Build-Deploy Workflow' 1.2.9
    [ "$status" -eq 0 ]
    [ "$(invocation_key)" = "img--Test-Docker-Build-Deploy-Workflow--1.2.9" ]
}

@test "platforms are sanitized into the matrix" {
    run_parse img build 1.0.0 'linux/amd64,linux/arm64,linux/foo--bar'
    [ "$status" -eq 0 ]
    local sans
    sans="$(jq -r '[.[].sanitized] | join(" ")' <<<"$(grep '^matrix=' "$GITHUB_OUTPUT" | cut -d= -f2-)")"
    [ "$sans" = "linux-amd64 linux-arm64 linux-foo-bar" ]
}

@test "an empty image-name or app-version fails" {
    run_parse '' build 1.0.0
    [ "$status" -ne 0 ]

    run_parse img build v
    [ "$status" -ne 0 ]
}

@test "two platforms that sanitize to one segment fail" {
    run_parse img build 1.0.0 'linux/amd64,linux-amd64'
    [ "$status" -ne 0 ]
}

@test "artifact names, cache scope, and the merge glob use the invocation key" {
    local digest legmeta cache_from cache_to pattern
    digest="$(yq -r '.jobs.build.steps[] | select(.name == "Upload digest") | .with.name' "$WORKFLOW")"
    legmeta="$(yq -r '.jobs.build.steps[] | select(.name == "Upload leg metadata") | .with.name' "$WORKFLOW")"
    pattern="$(yq -r '.jobs.merge.steps[] | select(.name == "Download per-leg digests") | .with.pattern' "$WORKFLOW")"
    cache_from="$(yq -r '.jobs.build.steps[] | select(.with."cache-from") | .with."cache-from"' "$WORKFLOW")"
    cache_to="$(yq -r '.jobs.build.steps[] | select(.with."cache-to") | .with."cache-to"' "$WORKFLOW")"

    local key='${{ needs.parse-platforms.outputs.invocation-key }}'
    local platform='${{ matrix.sanitized }}'
    [ "$digest" = "digests-${key}--${platform}" ]
    [ "$legmeta" = "legmeta-${key}--${platform}" ]
    [ "$pattern" = "digests-${key}--*" ]
    [ "$cache_from" = "type=gha,scope=${key}--${platform}" ]
    [ "$cache_to" = "type=gha,mode=max,scope=${key}--${platform}" ]
}

@test "a repeated artifact name fails the upload" {
    local overwrite
    overwrite="$(yq -r '.jobs.build.steps[] | select(.name == "Upload digest" or .name == "Upload leg metadata") | .with.overwrite' "$WORKFLOW")"
    [ "$overwrite" = $'false\nfalse' ]
}

@test "image-name stays the registry repository" {
    local outputs
    outputs="$(yq -r '.jobs.build.steps[] | select(.uses // "" | test("build-push-action")) | .with.outputs' "$WORKFLOW")"
    [[ "$outputs" == *'${{ inputs.image-name }}'* ]]
    [[ "$outputs" != *invocation-key* ]]
}

@test "the old image-name-only artifact name is gone" {
    run grep -n 'digests-${{ inputs.image-name }}--' "$WORKFLOW"
    [ "$status" -ne 0 ]
    run grep -n 'image-name namespaces the artifact' "$WORKFLOW"
    [ "$status" -ne 0 ]
}

@test "merge fails when the digest file count is not the platform count" {
    local script
    script="$(yq -r '.jobs.merge.steps[] | select(.name == "Create multi-platform manifest") | .run' "$WORKFLOW")"
    [[ "$script" == *"expected=\"\$(jq 'length' <<<\"\$PLATFORM_MATRIX\")\""* ]]
    [[ "$script" == *'find "${RUNNER_TEMP}/digests" -type f -print0'* ]]
    [[ "$script" == *'per-leg digests for this invocation, found ${#files[@]}'* ]]

    local matrix_env
    matrix_env="$(yq -r '.jobs.merge.steps[] | select(.name == "Create multi-platform manifest") | .env.PLATFORM_MATRIX' "$WORKFLOW")"
    [ "$matrix_env" = '${{ needs.parse-platforms.outputs.matrix }}' ]
}

@test "the integration test downloads leg metadata by invocation" {
    local multi ctx
    multi="$(yq -r '.jobs.verify.steps[] | select(.name == "Download per-leg metadata (multi)") | .with.pattern' "$TEST_WORKFLOW")"
    ctx="$(yq -r '.jobs.verify.steps[] | select(.name == "Download per-leg metadata (build-context delivery)") | .with.pattern' "$TEST_WORKFLOW")"
    [ "$multi" = 'legmeta-test-image--test-container--${{ steps.artifact_version.outputs.version }}--*' ]
    [ "$ctx" = 'legmeta-test-image-ctx--test-container-ctx--${{ steps.artifact_version.outputs.version }}--*' ]
}

@test "the integration test version segment matches the invocation key" {
    APP_VERSION='v1.2.3+abc' \
        GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/version_out" \
        run bash "$VERSION_STEP"
    [ "$status" -eq 0 ]
    local segment
    segment="$(grep '^version=' "${BATS_TEST_TMPDIR}/version_out" | cut -d= -f2-)"

    run_parse img build 'v1.2.3+abc'
    [ "$status" -eq 0 ]
    [ "$(invocation_key)" = "img--build--${segment}" ]
}
