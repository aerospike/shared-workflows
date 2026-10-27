#!/usr/bin/env bats
# Input validation tests for setup-kind-ako that do not need a cluster.

GIT_ROOT="$(git rev-parse --show-toplevel)"
ENTRYPOINT="$GIT_ROOT/.github/actions/setup-kind-ako/entrypoint.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export RUNNER_TEMP="$TEST_TMPDIR"
    export GITHUB_OUTPUT="$TEST_TMPDIR/output"
    export CLUSTER_SIZE=1
    export SERVER_IMAGE=aerospike/aerospike-server-enterprise:8.1.2.5
    export FEATURES_CONTENT=feature-key
    export ADMIN_PASSWORD=testpassword
}

teardown() {
    if [[ -n ${TEST_TMPDIR-} && -d $TEST_TMPDIR ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

@test "prepare writes the given password" {
    run "$ENTRYPOINT" prepare

    [ "$status" -eq 0 ]
    [[ "$output" == *"::add-mask::testpassword"* ]]
    grep -qx 'admin-password=testpassword' "$GITHUB_OUTPUT"
}

@test "prepare generates a password when none is given" {
    ADMIN_PASSWORD="" run "$ENTRYPOINT" prepare

    [ "$status" -eq 0 ]
    grep -Eqx 'admin-password=[0-9a-f]{32}' "$GITHUB_OUTPUT"
}

@test "prepare rejects a missing feature key" {
    FEATURES_CONTENT="" run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"features-content is required"* ]]
}

@test "prepare rejects a password with symbols" {
    ADMIN_PASSWORD='bad pass;word' run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"admin-password must be 8-128 letters or digits"* ]]
}

@test "prepare rejects cluster-size outside 1-8" {
    CLUSTER_SIZE=9 run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"cluster-size must be 1-8"* ]]

    CLUSTER_SIZE=0 run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
}

@test "prepare rejects a server-image with YAML characters" {
    SERVER_IMAGE='aerospike/server:1 # x' run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"server-image"* ]]
}

@test "prepare rejects a server-image without a tag" {
    SERVER_IMAGE=aerospike/aerospike-server-enterprise@sha256:0123abcd run "$ENTRYPOINT" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"server-image must be repository:tag"* ]]
}
