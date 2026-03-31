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

    # Verify expected pypi fixtures exist
    if [[ ! -f "$BUILD_ARTIFACTS_DIR/aerospike_hello-1.0.0-py3-none-any.whl" ]]; then
        echo "Error: Missing expected wheel fixture: aerospike_hello-1.0.0-py3-none-any.whl" >&2
        return 1
    fi
    if [[ ! -f "$BUILD_ARTIFACTS_DIR/aerospike-hello-1.0.0.tar.gz" ]]; then
        echo "Error: Missing expected sdist fixture: aerospike-hello-1.0.0.tar.gz" >&2
        return 1
    fi
}

teardown_file() {
    teardown_test_artifacts
}

@test "wheel is uploaded with correct target path" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aerospike_hello-1\.0\.0-py3-none-any\.whl[[:space:]] && $cmd =~ pypi-dev-local ]]; then
            found=true
            # Verify target path follows PyPI layout: {normalized-name}/{version}/{filename}
            [[ $cmd =~ pypi-dev-local/aerospike-hello/1\.0\.0/aerospike_hello-1\.0\.0-py3-none-any\.whl ]] || \
                (echo "Wrong target path for wheel: $cmd" >&2 && return 1)
            [[ $cmd =~ --build-name=test-build ]] || (echo "Missing --build-name: $cmd" >&2 && return 1)
            [[ $cmd =~ --build-number=12345-artifacts ]] || (echo "Missing --build-number: $cmd" >&2 && return 1)
            [[ $cmd =~ --project=test-project ]] || (echo "Missing --project: $cmd" >&2 && return 1)
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No wheel upload command found" >&2 && return 1)
}

@test "sdist is uploaded with correct target path" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aerospike-hello-1\.0\.0\.tar\.gz[[:space:]] && $cmd =~ pypi-dev-local ]]; then
            found=true
            # Verify target path follows PyPI layout
            [[ $cmd =~ pypi-dev-local/aerospike-hello/1\.0\.0/aerospike-hello-1\.0\.0\.tar\.gz ]] || \
                (echo "Wrong target path for sdist: $cmd" >&2 && return 1)
            [[ $cmd =~ --build-name=test-build ]] || (echo "Missing --build-name: $cmd" >&2 && return 1)
            [[ $cmd =~ --project=test-project ]] || (echo "Missing --project: $cmd" >&2 && return 1)
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No sdist upload command found" >&2 && return 1)
}

@test "pypi uploads include target-props with version and package_name" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local wheel_props=false
    local sdist_props=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aerospike_hello.*\.whl[[:space:]] && $cmd =~ pypi-dev-local ]]; then
            [[ $cmd =~ --target-props ]] || (echo "Missing --target-props on wheel upload: $cmd" >&2 && return 1)
            [[ $cmd =~ version=v1.0.0 ]] || (echo "Missing version prop: $cmd" >&2 && return 1)
            [[ $cmd =~ package_name=aerospike-hello ]] || (echo "Missing package_name prop: $cmd" >&2 && return 1)
            wheel_props=true
        fi
        if [[ $cmd =~ aerospike-hello-1\.0\.0\.tar\.gz[[:space:]] && $cmd =~ pypi-dev-local ]]; then
            [[ $cmd =~ --target-props ]] || (echo "Missing --target-props on sdist upload: $cmd" >&2 && return 1)
            [[ $cmd =~ version=v1.0.0 ]] || (echo "Missing version prop: $cmd" >&2 && return 1)
            [[ $cmd =~ package_name=aerospike-hello ]] || (echo "Missing package_name prop: $cmd" >&2 && return 1)
            sdist_props=true
        fi
    done <<< "$upload_commands"

    [[ $wheel_props == true ]] || (echo "No wheel upload with target-props found" >&2 && return 1)
    [[ $sdist_props == true ]] || (echo "No sdist upload with target-props found" >&2 && return 1)
}

@test "wheel .asc companion is uploaded with correct target path" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aerospike_hello-1\.0\.0-py3-none-any\.whl\.asc && $cmd =~ pypi-dev-local ]]; then
            [[ $cmd =~ pypi-dev-local/aerospike-hello/1\.0\.0/aerospike_hello-1\.0\.0-py3-none-any\.whl\.asc ]] || \
                (echo "Wrong target path for wheel .asc: $cmd" >&2 && return 1)
            found=true
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No .asc companion upload found for wheel" >&2 && return 1)
}

@test "sdist .asc companion is uploaded with correct target path" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aerospike-hello-1\.0\.0\.tar\.gz\.asc && $cmd =~ pypi-dev-local ]]; then
            [[ $cmd =~ pypi-dev-local/aerospike-hello/1\.0\.0/aerospike-hello-1\.0\.0\.tar\.gz\.asc ]] || \
                (echo "Wrong target path for sdist .asc: $cmd" >&2 && return 1)
            found=true
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No .asc companion upload found for sdist" >&2 && return 1)
}

@test "non-sdist .tar.gz files are not uploaded to pypi repository" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    # test.tar.gz should NOT appear in pypi-dev-local uploads
    local wrong_route=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ test\.tar\.gz && $cmd =~ pypi-dev-local ]]; then
            wrong_route=true
        fi
    done <<< "$upload_commands"

    [[ $wrong_route == false ]] || (echo "Non-sdist .tar.gz was uploaded to pypi repository" >&2 && return 1)
}
