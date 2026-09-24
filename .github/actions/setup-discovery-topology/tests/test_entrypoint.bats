#!/usr/bin/env bats
# Validation tests for setup-discovery-topology that do not need Docker.

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/setup-discovery-topology"
ENTRYPOINT="$ACTION_DIR/entrypoint.sh"

@test "entrypoint requires container-names" {
    run env \
        CONTAINER_NAMES="" \
        AEROSPIKE_NETWORK_NAME="aerospike-net" \
        CLIENT_IMAGE="alpine:3.20" \
        CLIENT_COMMAND="true" \
        bash "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"container-names is required"* ]]
}

@test "entrypoint requires aerospike-network-name" {
    run env \
        CONTAINER_NAMES="aerospike-1" \
        AEROSPIKE_NETWORK_NAME="" \
        CLIENT_IMAGE="alpine:3.20" \
        CLIENT_COMMAND="true" \
        bash "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"aerospike-network-name is required"* ]]
}

@test "entrypoint requires client-image" {
    run env \
        CONTAINER_NAMES="aerospike-1" \
        AEROSPIKE_NETWORK_NAME="aerospike-net" \
        CLIENT_IMAGE="" \
        CLIENT_COMMAND="true" \
        bash "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"client-image is required"* ]]
}

@test "entrypoint requires client-command" {
    run env \
        CONTAINER_NAMES="aerospike-1" \
        AEROSPIKE_NETWORK_NAME="aerospike-net" \
        CLIENT_IMAGE="alpine:3.20" \
        CLIENT_COMMAND="" \
        bash "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"client-command is required"* ]]
}

@test "entrypoint rejects an invalid endpoint hostname" {
    run env \
        CONTAINER_NAMES="aerospike-1" \
        AEROSPIKE_NETWORK_NAME="aerospike-net" \
        CLIENT_IMAGE="alpine:3.20" \
        CLIENT_COMMAND="true" \
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
