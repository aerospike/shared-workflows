#!/usr/bin/env bats
# Tests for fetch-conformance-fixtures path checks and dry-run.
# shellcheck disable=SC2030,SC2031 # each @test is a subshell; exports are intentional

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/fetch-conformance-fixtures"

# shellcheck source=/dev/null
source "$ACTION_DIR/lib.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export TEST_TMPDIR
    export GITHUB_WORKSPACE="$TEST_TMPDIR"
}

teardown() {
    if [[ -n ${TEST_TMPDIR-} && -d $TEST_TMPDIR ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
    unset DRY_RUN VERSION PACKAGE_NAME JF_PROJECT DESTINATION
    unset OIDC_PROVIDER_NAME OIDC_AUDIENCE GITHUB_OUTPUT GITHUB_WORKSPACE
}

@test "artifact path matches the conformance release layout" {
    run artifact_repo_path "database" "aerospike-client-conformance" "0.1.0"

    [ "$status" -eq 0 ]
    [ "$output" = "database-generic-dev-local/aerospike-client-conformance/0.1.0/aerospike-client-conformance-0.1.0.zip" ]
}

@test "version rejects a v prefix and a partial semver" {
    run validate_semver "v0.1.0"
    [ "$status" -ne 0 ]
    [[ "$output" == *"MAJOR.MINOR.PATCH"* ]]

    run validate_semver "0.1"
    [ "$status" -ne 0 ]
}

@test "destination stays under the workspace" {
    run resolve_destination "conformance-fixtures"
    [ "$status" -eq 0 ]
    [ "$output" = "$TEST_TMPDIR/conformance-fixtures" ]

    run resolve_destination "../escape"
    [ "$status" -ne 0 ]

    run resolve_destination "/tmp/fixtures"
    [ "$status" -ne 0 ]

    run resolve_destination "."
    [ "$status" -ne 0 ]
}

@test "dry-run prints the download and does not require jf or oidc" {
    export VERSION=0.1.0
    export DRY_RUN=true
    export DESTINATION=conformance-fixtures
    export GITHUB_OUTPUT="$TEST_TMPDIR/output"

    run "$ACTION_DIR/entrypoint.sh" fetch

    [ "$status" -eq 0 ]
    [[ "$output" == *"dry-run: jf rt download database-generic-dev-local/aerospike-client-conformance/0.1.0/aerospike-client-conformance-0.1.0.zip"* ]]
    grep -q '^artifact-path=database-generic-dev-local/aerospike-client-conformance/0.1.0/aerospike-client-conformance-0.1.0.zip$' "$GITHUB_OUTPUT"
    run grep -q '^fixtures-directory=' "$GITHUB_OUTPUT"
    [ "$status" -ne 0 ]
}

@test "a real fetch without oidc fails before download" {
    export VERSION=0.1.0
    export DRY_RUN=false

    run "$ACTION_DIR/entrypoint.sh" validate

    [ "$status" -ne 0 ]
    [[ "$output" == *"oidc-provider-name"* ]]
}
