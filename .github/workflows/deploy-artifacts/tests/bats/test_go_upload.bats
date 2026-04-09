#!/usr/bin/env bats

# Get absolute paths - use git root to find helpers
GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_ARTIFACTS_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts"
HELPERS_DIR="$DEPLOY_ARTIFACTS_DIR/tests/helpers"

load "$HELPERS_DIR/setup.bash"
load "$HELPERS_DIR/command_parsers.bash"
load "$HELPERS_DIR/assertions.bash"

setup_file() {
    setup_test_artifacts

    # Verify expected Go module fixture exists
    if [[ ! -f "$BUILD_ARTIFACTS_DIR/aeromod-v1.2.3.zip" ]]; then
        echo "Error: Missing expected Go module fixture: aeromod-v1.2.3.zip" >&2
        return 1
    fi
}

teardown_file() {
    teardown_test_artifacts
}

@test "go module zip is uploaded with correct GOPROXY target path" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aeromod-v1\.2\.3\.zip[[:space:]] && $cmd =~ go-dev-local ]]; then
            found=true
            # Verify target path follows GOPROXY layout: module/@v/version.zip
            [[ $cmd =~ go-dev-local/github\.com/aerospike/aeromod/@v/v1\.2\.3\.zip ]] || \
                (echo "Wrong target path for Go module zip: $cmd" >&2 && return 1)
            [[ $cmd =~ --build-name=test-build ]] || (echo "Missing --build-name: $cmd" >&2 && return 1)
            [[ $cmd =~ --build-number=12345-artifacts ]] || (echo "Missing --build-number: $cmd" >&2 && return 1)
            [[ $cmd =~ --project=test-project ]] || (echo "Missing --project: $cmd" >&2 && return 1)
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No Go module zip upload command found" >&2 && return 1)
}

@test "go module .mod sidecar is uploaded with correct target path" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ go-dev-local/github\.com/aerospike/aeromod/@v/v1\.2\.3\.mod ]]; then
            found=true
            [[ $cmd =~ --build-name=test-build ]] || (echo "Missing --build-name: $cmd" >&2 && return 1)
            [[ $cmd =~ --project=test-project ]] || (echo "Missing --project: $cmd" >&2 && return 1)
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No .mod sidecar upload command found" >&2 && return 1)
}

@test "go module .info sidecar is uploaded with correct target path" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ go-dev-local/github\.com/aerospike/aeromod/@v/v1\.2\.3\.info ]]; then
            found=true
            [[ $cmd =~ --build-name=test-build ]] || (echo "Missing --build-name: $cmd" >&2 && return 1)
            [[ $cmd =~ --project=test-project ]] || (echo "Missing --project: $cmd" >&2 && return 1)
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No .info sidecar upload command found" >&2 && return 1)
}

@test "go uploads include target-props with version and module path" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aeromod-v1\.2\.3\.zip[[:space:]] && $cmd =~ go-dev-local ]]; then
            [[ $cmd =~ --target-props ]] || (echo "Missing --target-props on Go upload: $cmd" >&2 && return 1)
            [[ $cmd =~ version=v1.0.0 ]] || (echo "Missing version prop: $cmd" >&2 && return 1)
            [[ $cmd =~ go\.module=github\.com/aerospike/aeromod ]] || (echo "Missing go.module prop: $cmd" >&2 && return 1)
            [[ $cmd =~ go\.version=v1\.2\.3 ]] || (echo "Missing go.version prop: $cmd" >&2 && return 1)
            found=true
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No Go upload with target-props found" >&2 && return 1)
}

@test "go module .asc companion is uploaded with correct target path" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aeromod-v1\.2\.3\.zip\.asc && $cmd =~ go-dev-local ]]; then
            [[ $cmd =~ go-dev-local/github\.com/aerospike/aeromod/@v/v1\.2\.3\.zip\.asc ]] || \
                (echo "Wrong target path for Go .asc: $cmd" >&2 && return 1)
            found=true
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No .asc companion upload found for Go module" >&2 && return 1)
}

@test "non-go-module .zip files are not uploaded to go repository" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    # test.zip should NOT appear in go-dev-local uploads
    local wrong_route=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ test\.zip && $cmd =~ go-dev-local ]]; then
            wrong_route=true
        fi
    done <<< "$upload_commands"

    [[ $wrong_route == false ]] || (echo "Non-Go-module .zip was uploaded to go repository" >&2 && return 1)

    # test.zip SHOULD appear in generic-dev-local uploads
    local found_in_generic=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ test\.zip && $cmd =~ generic-dev-local ]]; then
            found_in_generic=true
        fi
    done <<< "$upload_commands"

    [[ $found_in_generic == true ]] || (echo "test.zip not found in generic uploads" >&2 && return 1)
}
