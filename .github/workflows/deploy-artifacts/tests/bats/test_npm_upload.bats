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

    # Verify expected npm fixture exists
    if [[ ! -f "$BUILD_ARTIFACTS_DIR/aerospike-test-package-1.0.0.tgz" ]]; then
        echo "Error: Missing expected npm fixture: aerospike-test-package-1.0.0.tgz" >&2
        return 1
    fi
}

teardown_file() {
    teardown_test_artifacts
}

@test "npm packages are uploaded to correct repository" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    # Extract all upload commands
    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    # Find npm upload commands (targeting npm-dev-local)
    local npm_found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ \.tgz[[:space:]] && $cmd =~ npm-dev-local ]]; then
            npm_found=true
            # Verify standard flags
            [[ $cmd =~ jf\ +rt\ +upload ]] || (echo "Not a jf rt upload command: $cmd" >&2 && return 1)
            [[ $cmd =~ test-project-npm-dev-local ]] || (echo "Wrong repository: $cmd" >&2 && return 1)
            [[ $cmd =~ --build-name=test-build ]] || (echo "Missing --build-name: $cmd" >&2 && return 1)
            [[ $cmd =~ --build-number=12345-artifacts ]] || (echo "Missing --build-number: $cmd" >&2 && return 1)
            [[ $cmd =~ --project=test-project ]] || (echo "Missing --project: $cmd" >&2 && return 1)
            [[ $cmd =~ --flat=false ]] || (echo "Missing --flat=false: $cmd" >&2 && return 1)
        fi
    done <<< "$upload_commands"

    [[ $npm_found == true ]] || (echo "No npm upload commands found targeting npm-dev-local" >&2 && return 1)
}

@test "npm uploads include target-props with version and package_name" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local props_found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ \.tgz[[:space:]] && $cmd =~ npm-dev-local ]]; then
            [[ $cmd =~ --target-props ]] || (echo "Missing --target-props on npm upload: $cmd" >&2 && return 1)
            [[ $cmd =~ version=v1.0.0 ]] || (echo "Missing version prop: $cmd" >&2 && return 1)
            [[ $cmd =~ package_name= ]] || (echo "Missing package_name prop: $cmd" >&2 && return 1)
            props_found=true
        fi
    done <<< "$upload_commands"

    [[ $props_found == true ]] || (echo "No npm upload with target-props found" >&2 && return 1)
}

@test "npm .asc companions are uploaded" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local asc_found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ \.tgz\.asc && $cmd =~ npm-dev-local ]]; then
            asc_found=true
        fi
    done <<< "$upload_commands"

    [[ $asc_found == true ]] || (echo "No .asc companion upload found for npm packages" >&2 && return 1)
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
