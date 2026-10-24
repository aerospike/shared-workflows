#!/usr/bin/env bats
# Validation tests for setup-dns-server that do not need Docker.

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/setup-dns-server"
ENTRYPOINT="$ACTION_DIR/entrypoint.sh"

ZONE="\$ORIGIN dns.test.
@ 3600 IN SOA ns.dns.test. admin.dns.test. 1 60 60 60 1
seeds 1 IN A 192.0.2.10"

run_entrypoint() {
    run env \
        NETWORK_NAME="dns-net" \
        ZONE_CONTENT="$ZONE" \
        ZONE_NAME="dns.test" \
        "$@" \
        bash "$ENTRYPOINT"
}

@test "entrypoint requires network-name" {
    run_entrypoint NETWORK_NAME=""

    [ "$status" -ne 0 ]
    [[ "$output" == *"network-name is required"* ]]
}

@test "entrypoint rejects whitespace-only zone-content" {
    run_entrypoint ZONE_CONTENT=$'  \n\t\n'

    [ "$status" -ne 0 ]
    [[ "$output" == *"zone-content is required"* ]]
}

@test "entrypoint rejects zone-content without an SOA record" {
    run_entrypoint ZONE_CONTENT="seeds 1 IN A 192.0.2.10"

    [ "$status" -ne 0 ]
    [[ "$output" == *"zone-content has no SOA record"* ]]
}

@test "entrypoint requires zone-name" {
    run_entrypoint ZONE_NAME=""

    [ "$status" -ne 0 ]
    [[ "$output" == *"zone-name is required"* ]]
}

@test "entrypoint rejects an invalid zone-name" {
    run_entrypoint ZONE_NAME="not a zone"

    [ "$status" -ne 0 ]
    [[ "$output" == *"zone-name is not a valid domain name (got: 'not a zone')"* ]]
}

@test "entrypoint rejects an invalid container-name" {
    run_entrypoint CONTAINER_NAME="bad name!"

    [ "$status" -ne 0 ]
    [[ "$output" == *"container-name is not a valid Docker name (got: 'bad name!')"* ]]
}

@test "entrypoint rejects an invalid network-name" {
    run_entrypoint NETWORK_NAME="-net"

    [ "$status" -ne 0 ]
    [[ "$output" == *"network-name is not a valid Docker name"* ]]
}

@test "entrypoint rejects a non-integer startup-timeout" {
    run_entrypoint STARTUP_TIMEOUT="10s"

    [ "$status" -ne 0 ]
    [[ "$output" == *"startup-timeout must be a positive integer (got: '10s')"* ]]
}

@test "entrypoint shows help" {
    run bash "$ENTRYPOINT" --help

    [ "$status" -eq 0 ]
    [[ "$output" == *"Start CoreDNS on an existing Docker network"* ]]
}

@test "validate_zone_name accepts a trailing dot and underscore labels" {
    # shellcheck source=/dev/null
    source "$ENTRYPOINT"

    run validate_zone_name "_tcp.dns.test."
    [ "$status" -eq 0 ]

    run validate_zone_name "dns..test"
    [ "$status" -ne 0 ]
}
