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

@test "auto edition rejects ambiguous image repositories" {
    run --separate-stderr resolve_server_edition auto database-docker-virtual/aerospike-server-custom

    [ "$status" -ne 0 ]
    [[ "$stderr" == *"server-edition auto cannot infer edition"* ]]
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
    features_conf_path=$(mktemp)
    FEATURE_KEY_FILE=$(build_feature_key_file_directive enterprise "" "feature-key-version 2" "$features_conf_path")
    export FEATURE_KEY_FILE

    config_path="$TEST_TMPDIR/aerospike.conf"
    render_default_config "$config_path"

    grep -q "feature-key-file $features_conf_path" "$config_path"
}

@test "community with features content omits feature-key-file" {
    FEATURE_KEY_FILE=$(build_feature_key_file_directive community "" "feature-key-version 2" "/etc/aerospike/features.conf")
    export FEATURE_KEY_FILE

    config_path="$TEST_TMPDIR/aerospike.conf"
    render_default_config "$config_path"

    run grep -q "feature-key-file" "$config_path"
    [ "$status" -ne 0 ]
}

@test "community multi-node config omits feature-key-file" {
    FEATURE_KEY_FILE=$(build_feature_key_file_directive community "$TEST_TMPDIR/features.conf" "" "/etc/aerospike/features.conf")
    export FEATURE_KEY_FILE

    config_path="$TEST_TMPDIR/aerospike-multi-node.conf"
    render_multi_node_config "$config_path"

    run grep -q "feature-key-file" "$config_path"
    [ "$status" -ne 0 ]
}

@test "custom config feature-key-file directive can be detected" {
    config_path="$TEST_TMPDIR/aerospike.conf"
    cat > "$config_path" <<'EOF'
service {
    cluster-name docker
    feature-key-file /etc/aerospike/features.conf
}
EOF

    config_declares_feature_key_file "$config_path"
}

@test "custom community config can strip feature-key-file directive" {
    config_path="$TEST_TMPDIR/aerospike.conf"
    sanitized_path="$TEST_TMPDIR/aerospike-community.conf"
    cat > "$config_path" <<'EOF'
service {
    cluster-name docker
    feature-key-file /etc/aerospike/features.conf
}
EOF

    strip_feature_key_file_directive "$config_path" "$sanitized_path"

    run grep -q "feature-key-file" "$sanitized_path"
    [ "$status" -ne 0 ]
    grep -q "cluster-name docker" "$sanitized_path"
}

@test "custom enterprise config gains feature-key-file inside service" {
    config_path="$TEST_TMPDIR/aerospike.conf"
    injected_path="$TEST_TMPDIR/aerospike-injected.conf"
    cat > "$config_path" <<'EOF'
service {
    cluster-name docker
}
network {
    heartbeat {
        mode mesh
    }
}
EOF

    inject_feature_key_file_directive "$config_path" "$injected_path" "/etc/aerospike-custom/tmp.features"

    grep -q "    feature-key-file /etc/aerospike-custom/tmp.features" "$injected_path"
    # One directive, placed in the service context rather than after it.
    [ "$(grep -c 'feature-key-file' "$injected_path")" -eq 1 ]
    awk '
        /service \{/ { in_service = 1 }
        /feature-key-file/ { found = in_service }
        /^}/ { if (in_service) in_service = 0 }
        END { exit !found }
    ' "$injected_path"
}

@test "custom config rewrites an existing feature-key-file path" {
    config_path="$TEST_TMPDIR/aerospike.conf"
    injected_path="$TEST_TMPDIR/aerospike-injected.conf"
    cat > "$config_path" <<'EOF'
service {
	feature-key-file /tmp/caller-does-not-know-this-name
	cluster-name docker
}
EOF

    inject_feature_key_file_directive "$config_path" "$injected_path" "/etc/aerospike-custom/tmp.AbCdEf"

    grep -q $'\tfeature-key-file /etc/aerospike-custom/tmp.AbCdEf' "$injected_path"
    run grep -q "caller-does-not-know-this-name" "$injected_path"
    [ "$status" -ne 0 ]
    [ "$(grep -c 'feature-key-file' "$injected_path")" -eq 1 ]
}

@test "custom config without a service context gets one" {
    config_path="$TEST_TMPDIR/aerospike.conf"
    injected_path="$TEST_TMPDIR/aerospike-injected.conf"
    printf '%s\n' "namespace test {}" > "$config_path"

    inject_feature_key_file_directive "$config_path" "$injected_path" "/etc/aerospike-custom/features.conf"

    grep -q "namespace test {}" "$injected_path"
    grep -q "feature-key-file /etc/aerospike-custom/features.conf" "$injected_path"
    [ "$(grep -c 'feature-key-file' "$injected_path")" -eq 1 ]
}
