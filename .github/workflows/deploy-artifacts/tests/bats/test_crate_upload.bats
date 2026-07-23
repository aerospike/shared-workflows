#!/usr/bin/env bats

GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_ARTIFACTS_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts"
HELPERS_DIR="$DEPLOY_ARTIFACTS_DIR/tests/helpers"

load "$HELPERS_DIR/setup.bash"
load "$HELPERS_DIR/command_parsers.bash"
load "$HELPERS_DIR/assertions.bash"

setup_file() {
    setup_test_artifacts

    if [[ ! -f "$BUILD_ARTIFACTS_DIR/aerospike-3.0.0-alpha.1.crate" ]]; then
        echo "Error: Missing expected crate fixture: aerospike-3.0.0-alpha.1.crate" >&2
        return 1
    fi
}

teardown_file() {
    teardown_test_artifacts
}

@test "is_crate_package accepts valid aerospike crate fixture" {
    source "$DEPLOY_ARTIFACTS_DIR/package_utils.sh"
    source "$DEPLOY_ARTIFACTS_DIR/type_detection.sh"
    set +eu
    trap - ERR

    is_crate_package "$BUILD_ARTIFACTS_DIR/aerospike-3.0.0-alpha.1.crate"
}

@test "is_crate_package rejects invalid .crate fixture" {
    source "$DEPLOY_ARTIFACTS_DIR/package_utils.sh"
    source "$DEPLOY_ARTIFACTS_DIR/type_detection.sh"
    set +eu
    trap - ERR

    ! is_crate_package "$BUILD_ARTIFACTS_DIR/invalid-fixture.crate"
}

@test "get_crate_metadata reads aerospike name and version from Cargo.toml" {
    source "$DEPLOY_ARTIFACTS_DIR/package_utils.sh"
    set +eu
    trap - ERR

    local metadata
    metadata=$(get_crate_metadata "$BUILD_ARTIFACTS_DIR/aerospike-3.0.0-alpha.1.crate")
    [[ "$metadata" == "aerospike 3.0.0-alpha.1" ]]
}

@test "valid crate routes to crate dir with .asc companion after structuring" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true

    [[ -f "structured_build_artifacts/crate/aerospike-3.0.0-alpha.1.crate" ]]
    [[ -f "structured_build_artifacts/crate/aerospike-3.0.0-alpha.1.crate.asc" ]]

    local generic_crate_count
    generic_crate_count=$(find structured_build_artifacts/generic -name "*.crate" 2>/dev/null | wc -l | tr -d ' ')
    [[ "$generic_crate_count" -eq 0 ]]
}

@test "invalid .crate is not structured into crate or generic dirs" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true

    [[ ! -f "structured_build_artifacts/crate/invalid-fixture.crate" ]]
    [[ ! -f "structured_build_artifacts/generic/invalid-fixture.crate" ]]
}

@test "crate is uploaded to generic-dev-local with BUILD_NAME/VERSION path" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aerospike-3\.0\.0-alpha\.1\.crate[[:space:]] && $cmd =~ generic-dev-local ]]; then
            found=true
            [[ $cmd =~ generic-dev-local/test-build/v1\.0\.0/aerospike-3\.0\.0-alpha\.1\.crate ]] || \
                (echo "Wrong target path for crate: $cmd" >&2 && return 1)
            [[ $cmd =~ --build-name=test-build ]] || (echo "Missing --build-name: $cmd" >&2 && return 1)
            [[ $cmd =~ --project=test-project ]] || (echo "Missing --project: $cmd" >&2 && return 1)
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No crate upload command found" >&2 && return 1)
}

@test "crate upload includes cargo.name and cargo.version target-props" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aerospike-3\.0\.0-alpha\.1\.crate[[:space:]] && $cmd =~ generic-dev-local ]]; then
            [[ $cmd =~ --target-props ]] || (echo "Missing --target-props on crate upload: $cmd" >&2 && return 1)
            [[ $cmd =~ cargo\.name=aerospike ]] || (echo "Missing cargo.name prop: $cmd" >&2 && return 1)
            [[ $cmd =~ cargo\.version=3\.0\.0-alpha\.1 ]] || (echo "Missing cargo.version prop: $cmd" >&2 && return 1)
            [[ $cmd =~ package_name=aerospike ]] || (echo "Missing package_name prop: $cmd" >&2 && return 1)
            found=true
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No crate upload with target-props found" >&2 && return 1)
}

@test "crate .asc companion is uploaded beside crate in generic-dev-local" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aerospike-3\.0\.0-alpha\.1\.crate\.asc && $cmd =~ generic-dev-local ]]; then
            found=true
            [[ $cmd =~ generic-dev-local/test-build/v1\.0\.0/aerospike-3\.0\.0-alpha\.1\.crate\.asc ]] || \
                (echo "Wrong target path for crate .asc: $cmd" >&2 && return 1)
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No .asc companion upload found for crate" >&2 && return 1)
}

@test "invalid .crate is not uploaded to generic-dev-local" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    [[ "$upload_commands" != *"invalid-fixture.crate"* ]]
}
