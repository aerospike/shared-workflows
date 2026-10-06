#!/usr/bin/env bats
# Tests for setup-kind-ako rendering and the NodePort pin.

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/setup-kind-ako"

# shellcheck source=/dev/null
source "$ACTION_DIR/lib.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export TEST_TMPDIR
    export SETUP_KIND_AKO_STATE="$TEST_TMPDIR/state"
}

teardown() {
    if [[ -n ${TEST_TMPDIR-} && -d $TEST_TMPDIR ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

@test "pinned NodePort range is the Kubernetes default 30000-32767" {
    [ "$(pinned_nodeport_range)" = "30000-32767" ]
    [ "$(pinned_nodeport_start)" = "30000" ]
    [ "$(pinned_nodeport_end)" = "32767" ]
}

@test "expands ranges and single ports" {
    run expand_port_spec "30000-30002, 30100"

    [ "$status" -eq 0 ]
    [ "$output" = $'30000\n30001\n30002\n30100' ]
}

@test "rejects a reversed port range" {
    run expand_port_spec "30-10"

    [ "$status" -ne 0 ]
    [[ "$output" == *"greater than"* ]]
}

@test "rejects an enormous port range" {
    run expand_port_spec "1-65535"

    [ "$status" -ne 0 ]
    [[ "$output" == *"larger than 10000"* ]]
}

@test "ingress ports must sit outside the NodePort range" {
    run ingress_ports 31000 1

    [ "$status" -ne 0 ]
    [[ "$output" == *"inside the pinned NodePort range"* ]]
}

@test "nodePort probe expectations follow the pinned range" {
    [ "$(nodeport_probe_expectation 29999)" = "reject" ]
    [ "$(nodeport_probe_expectation 30000)" = "accept" ]
    [ "$(nodeport_probe_expectation 32767)" = "accept" ]
    [ "$(nodeport_probe_expectation 32768)" = "reject" ]
}

@test "API server flag must be exactly the pinned range" {
    run assert_pinned_nodeport_flag $'kube-apiserver\n--service-node-port-range=30000-32767\n--allow-privileged=true'

    [ "$status" -eq 0 ]
}

@test "API server flag with a space is accepted" {
    run assert_pinned_nodeport_flag $'kube-apiserver\n--service-node-port-range 30000-32767'

    [ "$status" -eq 0 ]
}

@test "missing NodePort flag fails" {
    run assert_pinned_nodeport_flag $'kube-apiserver\n--allow-privileged=true'

    [ "$status" -ne 0 ]
    [[ "$output" == *"does not set --service-node-port-range"* ]]
}

@test "widened NodePort flag fails" {
    run assert_pinned_nodeport_flag "--service-node-port-range=30000-40000"

    [ "$status" -ne 0 ]
    [[ "$output" == *"30000-40000"* ]]
    [[ "$output" == *"30000-32767"* ]]
}

@test "kind config pins the NodePort range even when client ports are narrow" {
    run render_kind_config "4000" 9000 1

    [ "$status" -eq 0 ]
    [[ "$output" == *"apiVersion: kubeadm.k8s.io/v1beta3"* ]]
    [[ "$output" == *"service-node-port-range: \"30000-32767\""* ]]
    [[ "$output" != *"- name: service-node-port-range"* ]]
    [[ "$output" != *"30000-32768"* ]]
    [[ "$output" != *"30000-40000"* ]]
    [[ "$output" == *"containerPort: 4000"* ]]
    [[ "$output" == *"hostPort: 4000"* ]]
    [[ "$output" == *"containerPort: 9000"* ]]
    [[ "$output" == *'listenAddress: "127.0.0.1"'* ]]
    [ "$(printf '%s\n' "$output" | grep -c 'containerPort:')" -eq 2 ]
}

@test "default client ports publish both ends of the NodePort range" {
    config=$(render_kind_config "30000-32767" 9000 2)

    [[ "$config" == *"containerPort: 30000"* ]]
    [[ "$config" == *"containerPort: 32767"* ]]
    [[ "$config" == *"containerPort: 9000"* ]]
    [[ "$config" == *"containerPort: 9001"* ]]
    # 32767-30000+1 NodePorts, plus two ingress ports.
    [ "$(printf '%s\n' "$config" | grep -c 'containerPort:')" -eq 2770 ]
}

@test "duplicate client and ingress ports are published once" {
    config=$(render_kind_config "9000" 9000 1)

    [ "$(printf '%s\n' "$config" | grep -c 'containerPort: 9000')" -eq 1 ]
}

@test "CoreDNS hosts entry is inserted and replaced" {
    corefile=$'.:53 {\n    errors\n    kubernetes cluster.local {\n    }\n}\n'
    updated=$(render_corefile_with_endpoint "$corefile" "10.0.0.2" "as-endpoint.test")
    [[ "$updated" == *"10.0.0.2 as-endpoint.test"* ]]
    [[ "$updated" == *"fallthrough"* ]]
    [[ "$updated" == *"# setup-kind-ako endpoint"* ]]

    again=$(render_corefile_with_endpoint "$updated" "10.0.0.3" "as-endpoint.test")
    [[ "$again" == *"10.0.0.3 as-endpoint.test"* ]]
    [[ "$again" != *"10.0.0.2 as-endpoint.test"* ]]
    [ "$(printf '%s\n' "$again" | grep -c 'setup-kind-ako endpoint')" -eq 1 ]
}

@test "runner hosts file keeps one endpoint line" {
    existing=$'127.0.0.1 localhost\n10.1.2.3 as-endpoint.test\n'
    updated=$(render_hosts_file "$existing" "127.0.0.1" "as-endpoint.test")

    [[ "$updated" == *"127.0.0.1 localhost"* ]]
    [[ "$updated" == *"127.0.0.1 as-endpoint.test # setup-kind-ako endpoint"* ]]
    [[ "$updated" != *"10.1.2.3 as-endpoint.test"* ]]
    [ "$(printf '%s\n' "$updated" | grep -c 'as-endpoint.test')" -eq 1 ]
}

@test "tcp-services ConfigMap maps one external port per pod" {
    manifest=$(render_tcp_services_configmap ingress-nginx 9000 aerospike aerocluster 2 3000)

    [[ "$manifest" == *"name: tcp-services"* ]]
    [[ "$manifest" == *'"9000": "aerospike/aerocluster-0-0:3000"'* ]]
    [[ "$manifest" == *'"9001": "aerospike/aerocluster-0-1:3000"'* ]]
}

@test "ingress chart does not publish host ports 80 and 443" {
    values=$(render_ingress_values)

    [[ "$values" == *"enabled: false"* ]]
    [[ "$values" != *"enabled: true"* ]]
}

@test "ingress patch points the controller at tcp-services and host ports" {
    patch=$(render_ingress_container_patch ingress-nginx 9000 2)

    python3 -m json.tool <<<"$patch" >/dev/null
    [[ "$patch" == *"--tcp-services-configmap=ingress-nginx/tcp-services"* ]]
    [[ "$patch" == *'"hostPort":9000'* ]]
    [[ "$patch" == *'"hostPort":9001'* ]]
}

@test "AerospikeCluster uses configuredIP and a single shared hostname is not a port map" {
    manifest=$(render_cluster_manifest aerospike aerocluster aerospike/aerospike-server-enterprise:8.1.2.5 2)

    [[ "$manifest" == *"skipWorkDirValidate: true"* ]]
    [[ "$manifest" == *"work-directory: /opt/aerospike"* ]]
    [[ "$manifest" == *"path: /opt/aerospike"* ]]
    [[ "$manifest" == *"alternateAccess: configuredIP"* ]]
    [[ "$manifest" == *"multiPodPerHost: true"* ]]
    [[ "$manifest" == *"feature-key-file: /etc/aerospike/secret/features.conf"* ]]
    [[ "$manifest" == *"replication-factor: 2"* ]]
    [[ "$manifest" == *"size: 2"* ]]
    [[ "$manifest" == *"data-size: 536870912"* ]]
}

@test "single-node cluster uses replication factor 1" {
    manifest=$(render_cluster_manifest aerospike aerocluster aerospike/aerospike-server:1.0.0 1)

    [[ "$manifest" == *"size: 1"* ]]
    [[ "$manifest" == *"replication-factor: 1"* ]]
}

@test "RBAC binds the watched namespace to the aerospike-cluster role" {
    manifest=$(render_rbac_manifest aerospike)

    [[ "$manifest" == *"name: aerospike-cluster-aerospike"* ]]
    [[ "$manifest" == *"name: aerospike-cluster"* ]]
    [[ "$manifest" == *"namespace: aerospike"* ]]
}

@test "record-inputs stores a feature key and rejects a missing one" {
    printf 'feature-key\n' >"$TEST_TMPDIR/features.conf"
    export FEATURES_FILE="$TEST_TMPDIR/features.conf"
    export FEATURES_CONTENT=""
    export ADMIN_PASSWORD="testpassword"
    export CLIENT_PORTS="4000"
    unset CLUSTER_SIZE

    run "$ACTION_DIR/entrypoint.sh" record-inputs

    [ "$status" -eq 0 ]
    [ -s "$SETUP_KIND_AKO_STATE/features.conf" ]
    # shellcheck disable=SC1090
    source "$SETUP_KIND_AKO_STATE/env.sh"
    [ "$CLIENT_PORTS" = "4000" ]
    [ "$CLUSTER_SIZE" = "1" ]

    unset FEATURES_FILE
    export FEATURES_CONTENT=""
    run "$ACTION_DIR/entrypoint.sh" record-inputs

    [ "$status" -ne 0 ]
    [[ "$output" == *"features-file or features-content is required"* ]]
}

@test "record-inputs rejects an ingress port inside the NodePort range" {
    printf 'feature-key\n' >"$TEST_TMPDIR/features.conf"
    export FEATURES_FILE="$TEST_TMPDIR/features.conf"
    export ADMIN_PASSWORD="testpassword"
    export INGRESS_PORT_BASE="32000"

    run "$ACTION_DIR/entrypoint.sh" record-inputs

    [ "$status" -ne 0 ]
    [[ "$output" == *"inside the pinned NodePort range"* ]]
}
