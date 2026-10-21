#!/usr/bin/env bats
# Validation tests for setup-discovery-topology that do not need Docker.

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/setup-discovery-topology"
ENTRYPOINT="$ACTION_DIR/entrypoint.sh"

@test "entrypoint requires container-names" {
    run env \
        CONTAINER_NAMES="" \
        AEROSPIKE_NETWORK_NAME="aerospike-net" \
        bash "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"container-names is required"* ]]
}

@test "entrypoint requires aerospike-network-name" {
    run env \
        CONTAINER_NAMES="aerospike-1" \
        AEROSPIKE_NETWORK_NAME="" \
        bash "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"aerospike-network-name is required"* ]]
}

@test "entrypoint rejects an invalid endpoint hostname" {
    run env \
        CONTAINER_NAMES="aerospike-1" \
        AEROSPIKE_NETWORK_NAME="aerospike-net" \
        ENDPOINT_HOSTNAME="not a host" \
        bash "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"endpoint-hostname is not a valid hostname"* ]]
}

@test "entrypoint shows help" {
    run bash "$ENTRYPOINT" --help

    [ "$status" -eq 0 ]
    [[ "$output" == *"L2 discovery topology"* ]]
}

@test "entrypoint rejects a non-integer client-network-mtu" {
    run env \
        CONTAINER_NAMES="aerospike-1" \
        AEROSPIKE_NETWORK_NAME="aerospike-net" \
        CLIENT_NETWORK_MTU="1280x" \
        bash "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"client-network-mtu must be a positive integer (got: '1280x')"* ]]
}

@test "entrypoint rejects a zero client-network-mtu" {
    run env \
        CONTAINER_NAMES="aerospike-1" \
        AEROSPIKE_NETWORK_NAME="aerospike-net" \
        CLIENT_NETWORK_MTU="0" \
        bash "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"client-network-mtu must be a positive integer (got: '0')"* ]]
}

@test "entrypoint rejects a proxy-sysctls entry without a value" {
    run env \
        CONTAINER_NAMES="aerospike-1" \
        AEROSPIKE_NETWORK_NAME="aerospike-net" \
        PROXY_SYSCTLS="net.core.somaxconn=1024,net.ipv4.tcp_fin_timeout" \
        bash "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"proxy-sysctls entries must be key=value (got: 'net.ipv4.tcp_fin_timeout')"* ]]
}

@test "entrypoint rejects a proxy-sysctls entry with an invalid key" {
    run env \
        CONTAINER_NAMES="aerospike-1" \
        AEROSPIKE_NETWORK_NAME="aerospike-net" \
        PROXY_SYSCTLS="net ipv4=1" \
        bash "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"proxy-sysctls entries must be key=value (got: 'net ipv4=1')"* ]]
}

@test "entrypoint rejects an empty proxy-sysctls entry" {
    run env \
        CONTAINER_NAMES="aerospike-1" \
        AEROSPIKE_NETWORK_NAME="aerospike-net" \
        PROXY_SYSCTLS="net.core.somaxconn=1024,,net.ipv4.tcp_fin_timeout=30" \
        bash "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"proxy-sysctls entries must be key=value (got: '')"* ]]
}
