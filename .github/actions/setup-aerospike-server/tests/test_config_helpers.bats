#!/usr/bin/env bats
# Tests for Aerospike Server edition-specific config generation.

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/setup-aerospike-server"

# shellcheck source=/dev/null
source "$ACTION_DIR/config-helpers.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export TEST_TMPDIR
}

teardown() {
    if [[ -n ${TEST_TMPDIR-} && -d $TEST_TMPDIR ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

render_default_config() {
    local target=$1

    export SECURITY=""
    export REPLICATION_FACTOR=1
    export NAMESPACE
    NAMESPACE=$("$ACTION_DIR/render-template.sh" "$ACTION_DIR/templates/namespace-memory.conf")

    "$ACTION_DIR/render-template.sh" "$ACTION_DIR/templates/default.conf" "$target"
}

render_multi_node_config() {
    local target=$1

    export SECURITY=""
    export REPLICATION_FACTOR=2
    export MESH_SEEDS="        mesh-seed-address-port aerospike-1 3002"
    export NAMESPACE
    NAMESPACE=$("$ACTION_DIR/render-template.sh" "$ACTION_DIR/templates/namespace-memory.conf")

    "$ACTION_DIR/render-template.sh" "$ACTION_DIR/templates/multi-node.conf" "$target"
}

@test "auto edition detects enterprise image repositories" {
    run resolve_server_edition auto database-docker-virtual/aerospike-server-enterprise

    [ "$status" -eq 0 ]
    [ "$output" = "enterprise" ]
}

@test "auto edition detects community image repositories" {
    run resolve_server_edition auto database-docker-virtual/aerospike-server

    [ "$status" -eq 0 ]
    [ "$output" = "community" ]
}

@test "explicit edition overrides auto detection" {
    run resolve_server_edition community database-docker-virtual/aerospike-server-enterprise

    [ "$status" -eq 0 ]
    [ "$output" = "community" ]
}

@test "invalid edition is rejected" {
    run resolve_server_edition professional database-docker-virtual/aerospike-server

    [ "$status" -ne 0 ]
}

@test "enterprise with features content renders feature-key-file" {
    FEATURE_KEY_FILE=$(build_feature_key_file_directive enterprise "" "feature-key-version 2")
    export FEATURE_KEY_FILE

    config_path="$TEST_TMPDIR/aerospike.conf"
    render_default_config "$config_path"

    grep -q "feature-key-file /etc/aerospike/features.conf" "$config_path"
}

@test "community with features content omits feature-key-file" {
    FEATURE_KEY_FILE=$(build_feature_key_file_directive community "" "feature-key-version 2")
    export FEATURE_KEY_FILE

    config_path="$TEST_TMPDIR/aerospike.conf"
    render_default_config "$config_path"

    run grep -q "feature-key-file" "$config_path"
    [ "$status" -ne 0 ]
}

@test "community multi-node config omits feature-key-file" {
    FEATURE_KEY_FILE=$(build_feature_key_file_directive community "$TEST_TMPDIR/features.conf" "")
    export FEATURE_KEY_FILE

    config_path="$TEST_TMPDIR/aerospike-multi-node.conf"
    render_multi_node_config "$config_path"

    run grep -q "feature-key-file" "$config_path"
    [ "$status" -ne 0 ]
}

@test "community does not mount features file" {
    run should_use_features_file community "$TEST_TMPDIR/features.conf"

    [ "$status" -ne 0 ]
}

@test "enterprise mounts features file" {
    should_use_features_file enterprise "$TEST_TMPDIR/features.conf"
}
