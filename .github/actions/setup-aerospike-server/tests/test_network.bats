#!/usr/bin/env bats
# Tests for create-network.sh and subnet_node_addresses.

bats_require_minimum_version 1.5.0

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/setup-aerospike-server"
CREATE_NETWORK="$ACTION_DIR/create-network.sh"

# shellcheck source=/dev/null
source "$ACTION_DIR/config-helpers.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export TEST_TMPDIR
    export DOCKER_STUB_DIR="$TEST_TMPDIR/docker"
    export GITHUB_OUTPUT="$TEST_TMPDIR/github-output"
    mkdir -p "$TEST_TMPDIR/bin" "$DOCKER_STUB_DIR"
    cat >"$TEST_TMPDIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
"network inspect")
    [[ -f $DOCKER_STUB_DIR/network-subnets ]] || exit 1
    cat "$DOCKER_STUB_DIR/network-subnets"
    ;;
"network create")
    printf '%s\n' "$@" >"$DOCKER_STUB_DIR/network-create.args"
    ;;
esac
STUB
    chmod +x "$TEST_TMPDIR/bin/docker"
    PATH="$TEST_TMPDIR/bin:$PATH"
}

teardown() {
    if [[ -n ${TEST_TMPDIR-} && -d $TEST_TMPDIR ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

@test "without network-subnet the network is created as before" {
    run "$CREATE_NETWORK" --network aerospike-net --subnet ""
    [ "$status" -eq 0 ]

    printf '%s\n' network create aerospike-net | diff -u - "$DOCKER_STUB_DIR/network-create.args"
    [ "$(cat "$GITHUB_OUTPUT")" = "network-name=aerospike-net" ]
}

@test "without network-subnet an existing network is reused" {
    echo "10.89.0.0/24 " >"$DOCKER_STUB_DIR/network-subnets"

    run "$CREATE_NETWORK" --network aerospike-net --subnet ""
    [ "$status" -eq 0 ]

    [ ! -e "$DOCKER_STUB_DIR/network-create.args" ]
    [[ $output == *"Docker network already exists: aerospike-net"* ]]
}

@test "network-subnet creates the network with that subnet" {
    run "$CREATE_NETWORK" --network aerospike-net --subnet 172.30.0.0/24
    [ "$status" -eq 0 ]

    printf '%s\n' network create --subnet 172.30.0.0/24 aerospike-net | diff -u - "$DOCKER_STUB_DIR/network-create.args"
}

@test "network-subnet reuses an existing network with the same subnet" {
    echo "172.30.0.0/24 " >"$DOCKER_STUB_DIR/network-subnets"

    run "$CREATE_NETWORK" --network aerospike-net --subnet 172.30.0.0/24
    [ "$status" -eq 0 ]

    [ ! -e "$DOCKER_STUB_DIR/network-create.args" ]
}

@test "network-subnet fails on an existing network with a different subnet" {
    echo "10.89.0.0/24 " >"$DOCKER_STUB_DIR/network-subnets"

    run --separate-stderr "$CREATE_NETWORK" --network aerospike-net --subnet 172.30.0.0/24
    [ "$status" -ne 0 ]

    [ "$stderr" = "Error: Docker network aerospike-net already exists with subnet(s) '10.89.0.0/24', not network-subnet 172.30.0.0/24" ]
    [ ! -e "$GITHUB_OUTPUT" ]
}

@test "subnet_node_addresses skips the network and gateway addresses" {
    run subnet_node_addresses 10.1.2.72/29 5

    [ "$status" -eq 0 ]
    [ "$output" = $'10.1.2.74\n10.1.2.75\n10.1.2.76\n10.1.2.77\n10.1.2.78' ]
}

@test "subnet_node_addresses rejects a subnet without room for the nodes" {
    run --separate-stderr subnet_node_addresses 10.1.2.72/29 6

    [ "$status" -ne 0 ]
    [[ $stderr == *"has no room for 6 nodes"* ]]
}

@test "subnet_node_addresses rejects malformed subnets" {
    for subnet in 172.30.0.0 172.30.0.0/31 256.0.0.0/24 fd00::/64 172.30.0.1/24 "172.30.0.0/24 "; do
        run --separate-stderr subnet_node_addresses "$subnet" 1
        [ "$status" -ne 0 ]
        [[ $stderr == "Error: network-subnet"* ]]
    done
}
