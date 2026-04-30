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

    if [[ ! -f "$BUILD_ARTIFACTS_DIR/aerospike-hello-0.4.2.tgz" ]]; then
        echo "Error: Missing expected helm fixture: aerospike-hello-0.4.2.tgz" >&2
        return 1
    fi
    if [[ ! -f "$BUILD_ARTIFACTS_DIR/aerospike-hello-0.4.2.tgz.prov" ]]; then
        echo "Error: Missing expected helm fixture: aerospike-hello-0.4.2.tgz.prov" >&2
        return 1
    fi
}

teardown_file() {
    teardown_test_artifacts
}

@test "Helm chart is uploaded with correct target path" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aerospike-hello-0\.4\.2\.tgz[[:space:]] && $cmd =~ helm-dev-local ]]; then
            found=true
            # Verify target path follows classic Helm repo layout: {chart}/{version}/{filename}
            [[ $cmd =~ helm-dev-local/aerospike-hello/0\.4\.2/aerospike-hello-0\.4\.2\.tgz ]] || \
                (echo "Wrong target path for chart: $cmd" >&2 && return 1)
            [[ $cmd =~ --build-name=test-build ]] || (echo "Missing --build-name: $cmd" >&2 && return 1)
            [[ $cmd =~ --build-number=12345-artifacts ]] || (echo "Missing --build-number: $cmd" >&2 && return 1)
            [[ $cmd =~ --project=test-project ]] || (echo "Missing --project: $cmd" >&2 && return 1)
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No helm chart upload command found" >&2 && return 1)
}

@test "Helm chart upload includes target-props with helm.name and helm.version" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aerospike-hello-0\.4\.2\.tgz[[:space:]] && $cmd =~ helm-dev-local ]]; then
            found=true
            [[ $cmd =~ helm\.name=aerospike-hello ]] || \
                (echo "Missing helm.name target-prop: $cmd" >&2 && return 1)
            [[ $cmd =~ helm\.version=0\.4\.2 ]] || \
                (echo "Missing helm.version target-prop: $cmd" >&2 && return 1)
            [[ $cmd =~ package_name=aerospike-hello ]] || \
                (echo "Missing package_name target-prop: $cmd" >&2 && return 1)
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No helm chart upload command found" >&2 && return 1)
}

@test "Helm .prov companion is uploaded alongside the chart" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    local upload_commands
    upload_commands=$(extract_upload_commands "$output")

    local found=false
    while IFS= read -r cmd; do
        if [[ $cmd =~ aerospike-hello-0\.4\.2\.tgz\.prov[[:space:]] && $cmd =~ helm-dev-local ]]; then
            found=true
            [[ $cmd =~ helm-dev-local/aerospike-hello/0\.4\.2/aerospike-hello-0\.4\.2\.tgz\.prov ]] || \
                (echo "Wrong target path for .prov: $cmd" >&2 && return 1)
        fi
    done <<< "$upload_commands"

    [[ $found == true ]] || (echo "No helm .prov upload command found" >&2 && return 1)
}
