#!/usr/bin/env bats
# Tests for setup-kind-ako rendering and input validation.

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/setup-kind-ako"

# shellcheck source=/dev/null
source "$ACTION_DIR/lib.sh"

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

@test "ingress ports start at 9000, one per pod" {
    [ "$(ingress_ports 3)" = $'9000\n9001\n9002' ]
}

@test "cluster-size outside 1-8 is rejected" {
    run ingress_ports 9

    [ "$status" -ne 0 ]
    [[ "$output" == *"cluster-size must be 1-8"* ]]

    run ingress_ports 0

    [ "$status" -ne 0 ]
}

@test "CoreDNS hosts entry is inserted and replaced" {
    corefile=$'.:53 {\n    errors\n    kubernetes cluster.local {\n    }\n}\n'
    updated=$(render_corefile_with_endpoint "$corefile" "10.0.0.2")
    [[ "$updated" == *"10.0.0.2 as-endpoint.test"* ]]
    [[ "$updated" == *"fallthrough"* ]]
    [[ "$updated" == *"# setup-kind-ako endpoint"* ]]

    again=$(render_corefile_with_endpoint "$updated" "10.0.0.3")
    [[ "$again" == *"10.0.0.3 as-endpoint.test"* ]]
    [[ "$again" != *"10.0.0.2 as-endpoint.test"* ]]
    [ "$(printf '%s\n' "$again" | grep -c 'setup-kind-ako endpoint')" -eq 1 ]
}

@test "CoreDNS entry needs a node IP" {
    run render_corefile_with_endpoint $'.:53 {\n}\n' ""

    [ "$status" -ne 0 ]
    [[ "$output" == *"not an IP"* ]]
}

@test "runner hosts file keeps one endpoint line" {
    existing=$'127.0.0.1 localhost\n10.1.2.3 as-endpoint.test\n'
    updated=$(render_hosts_file "$existing" 172.18.0.2)

    [[ "$updated" == *"127.0.0.1 localhost"* ]]
    [[ "$updated" == *"172.18.0.2 as-endpoint.test # setup-kind-ako endpoint"* ]]
    [[ "$updated" != *"10.1.2.3 as-endpoint.test"* ]]
    [ "$(printf '%s\n' "$updated" | grep -c 'as-endpoint.test')" -eq 1 ]
}

@test "ingress values map one tcp-services port per pod" {
    values=$(render_ingress_values 2)

    [[ "$values" == *'"9000": "aerospike/aerocluster-0-0:3000"'* ]]
    [[ "$values" == *'"9001": "aerospike/aerocluster-0-1:3000"'* ]]
    [[ "$values" == *"type: Recreate"* ]]
}

@test "AerospikeCluster uses configuredIP and a single shared hostname is not a port map" {
    manifest=$(render_cluster_manifest aerospike/aerospike-server-enterprise:8.1.2.5 2)

    [[ "$manifest" == *"name: aerocluster"* ]]
    [[ "$manifest" == *"namespace: aerospike"* ]]
    [[ "$manifest" == *"skipWorkDirValidate: true"* ]]
    [[ "$manifest" == *"work-directory: /opt/aerospike"* ]]
    [[ "$manifest" == *"path: /opt/aerospike"* ]]
    [[ "$manifest" == *"alternateAccess: configuredIP"* ]]
    [[ "$manifest" == *"multiPodPerHost: true"* ]]
    [[ "$manifest" == *"feature-key-file: /etc/aerospike/secret/features.conf"* ]]
    [[ "$manifest" == *"port: 3000"* ]]
    [[ "$manifest" == *"replication-factor: 2"* ]]
    [[ "$manifest" == *"size: 2"* ]]
    [[ "$manifest" == *"data-size: 536870912"* ]]
}

@test "single-node cluster uses replication factor 1" {
    manifest=$(render_cluster_manifest aerospike/aerospike-server:1.0.0 1)

    [[ "$manifest" == *"size: 1"* ]]
    [[ "$manifest" == *"replication-factor: 1"* ]]
}

@test "server-image with YAML characters is rejected" {
    run render_cluster_manifest 'aerospike/server:1 # x' 1

    [ "$status" -ne 0 ]
    [[ "$output" == *"server-image"* ]]
}

@test "RBAC binds the watched namespace to the aerospike-cluster role" {
    manifest=$(render_rbac_manifest)

    [[ "$manifest" == *"name: aerospike-cluster-aerospike"* ]]
    [[ "$manifest" == *"name: aerospike-cluster"* ]]
    [[ "$manifest" == *"namespace: aerospike"* ]]
}

@test "prepare writes the given password" {
    run "$ACTION_DIR/entrypoint.sh" prepare

    [ "$status" -eq 0 ]
    [[ "$output" == *"::add-mask::testpassword"* ]]
    grep -qx 'admin-password=testpassword' "$GITHUB_OUTPUT"
}

@test "prepare generates a password when none is given" {
    ADMIN_PASSWORD="" run "$ACTION_DIR/entrypoint.sh" prepare

    [ "$status" -eq 0 ]
    grep -Eqx 'admin-password=[0-9a-f]{32}' "$GITHUB_OUTPUT"
}

@test "prepare rejects a missing feature key" {
    FEATURES_CONTENT="" run "$ACTION_DIR/entrypoint.sh" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"features-content is required"* ]]
}

@test "prepare rejects a password with symbols" {
    ADMIN_PASSWORD='bad pass;word' run "$ACTION_DIR/entrypoint.sh" prepare

    [ "$status" -ne 0 ]
    [[ "$output" == *"admin-password must be 8-128 letters or digits"* ]]
}
