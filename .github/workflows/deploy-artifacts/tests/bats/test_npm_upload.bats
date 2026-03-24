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

    # Verify expected npm fixtures exist
    if [[ ! -f "$BUILD_ARTIFACTS_DIR/aerospike-test-package-1.0.0.tgz" ]]; then
        echo "Error: Missing expected scoped npm fixture: aerospike-test-package-1.0.0.tgz" >&2
        return 1
    fi
    if [[ ! -f "$BUILD_ARTIFACTS_DIR/aerospike-6.0.0.tgz" ]]; then
        echo "Error: Missing expected unscoped npm fixture: aerospike-6.0.0.tgz" >&2
        return 1
    fi
}

teardown_file() {
    teardown_test_artifacts
}

@test "scoped npm package is uploaded with correct target path" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aerospike-test-package-1\.0\.0\.tgz[[:space:]] && $cmd =~ npm-dev-local ]]; then
            found=true
            # Verify target path follows npm layout: @scope/name/-/filename.tgz
            [[ $cmd =~ npm-dev-local/@aerospike/test-package/-/aerospike-test-package-1\.0\.0\.tgz ]] || \
                (echo "Wrong target path for scoped package: $cmd" >&2 && return 1)
            [[ $cmd =~ --build-name=test-build ]] || (echo "Missing --build-name: $cmd" >&2 && return 1)
            [[ $cmd =~ --build-number=12345-artifacts ]] || (echo "Missing --build-number: $cmd" >&2 && return 1)
            [[ $cmd =~ --project=test-project ]] || (echo "Missing --project: $cmd" >&2 && return 1)
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No scoped npm upload command found" >&2 && return 1)
}

@test "unscoped npm package is uploaded with correct target path" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aerospike-6\.0\.0\.tgz[[:space:]] && $cmd =~ npm-dev-local ]]; then
            found=true
            # Verify target path follows npm layout: name/-/filename.tgz
            [[ $cmd =~ npm-dev-local/aerospike/-/aerospike-6\.0\.0\.tgz ]] || \
                (echo "Wrong target path for unscoped package: $cmd" >&2 && return 1)
            [[ $cmd =~ --build-name=test-build ]] || (echo "Missing --build-name: $cmd" >&2 && return 1)
            [[ $cmd =~ --project=test-project ]] || (echo "Missing --project: $cmd" >&2 && return 1)
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No unscoped npm upload command found" >&2 && return 1)
}

@test "npm uploads include target-props with version and package_name" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local scoped_props=false
    local unscoped_props=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aerospike-test-package.*\.tgz[[:space:]] && $cmd =~ npm-dev-local ]]; then
            [[ $cmd =~ --target-props ]] || (echo "Missing --target-props on scoped npm upload: $cmd" >&2 && return 1)
            [[ $cmd =~ version=v1.0.0 ]] || (echo "Missing version prop: $cmd" >&2 && return 1)
            [[ $cmd =~ package_name= ]] || (echo "Missing package_name prop: $cmd" >&2 && return 1)
            scoped_props=true
        fi
        if [[ $cmd =~ aerospike-6\.0\.0\.tgz[[:space:]] && $cmd =~ npm-dev-local ]]; then
            [[ $cmd =~ --target-props ]] || (echo "Missing --target-props on unscoped npm upload: $cmd" >&2 && return 1)
            [[ $cmd =~ version=v1.0.0 ]] || (echo "Missing version prop: $cmd" >&2 && return 1)
            [[ $cmd =~ package_name=aerospike ]] || (echo "Missing package_name prop: $cmd" >&2 && return 1)
            unscoped_props=true
        fi
    done <<< "$upload_commands"

    [[ $scoped_props == true ]] || (echo "No scoped npm upload with target-props found" >&2 && return 1)
    [[ $unscoped_props == true ]] || (echo "No unscoped npm upload with target-props found" >&2 && return 1)
}

@test "npm .asc companions are uploaded with correct target path" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local scoped_asc=false
    local unscoped_asc=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aerospike-test-package-1\.0\.0\.tgz\.asc && $cmd =~ npm-dev-local ]]; then
            [[ $cmd =~ npm-dev-local/@aerospike/test-package/-/aerospike-test-package-1\.0\.0\.tgz\.asc ]] || \
                (echo "Wrong target path for scoped .asc: $cmd" >&2 && return 1)
            scoped_asc=true
        fi
        if [[ $cmd =~ aerospike-6\.0\.0\.tgz\.asc && $cmd =~ npm-dev-local ]]; then
            [[ $cmd =~ npm-dev-local/aerospike/-/aerospike-6\.0\.0\.tgz\.asc ]] || \
                (echo "Wrong target path for unscoped .asc: $cmd" >&2 && return 1)
            unscoped_asc=true
        fi
    done <<< "$upload_commands"

    [[ $scoped_asc == true ]] || (echo "No .asc companion upload found for scoped npm package" >&2 && return 1)
    [[ $unscoped_asc == true ]] || (echo "No .asc companion upload found for unscoped npm package" >&2 && return 1)
}

@test "non-npm .tgz files are not uploaded to npm repository" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    # generic-archive.tgz should NOT appear in npm-dev-local uploads
    local wrong_route=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ generic-archive\.tgz && $cmd =~ npm-dev-local ]]; then
            wrong_route=true
        fi
    done <<< "$upload_commands"

    [[ $wrong_route == false ]] || (echo "Non-npm .tgz was uploaded to npm repository" >&2 && return 1)
}
