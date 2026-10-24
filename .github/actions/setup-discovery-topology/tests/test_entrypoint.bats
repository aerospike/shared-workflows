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

@test "entrypoint rejects an invalid client-network-mtu" {
    run env CONTAINER_NAMES="aerospike-1" AEROSPIKE_NETWORK_NAME="aerospike-net" CLIENT_NETWORK_MTU="0" bash "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"client-network-mtu must be a positive integer (got: '0')"* ]]
}

@test "entrypoint rejects a proxy-sysctls entry that is not key=value" {
    run env CONTAINER_NAMES="aerospike-1" AEROSPIKE_NETWORK_NAME="aerospike-net" PROXY_SYSCTLS="net.core.somaxconn=1024,net.ipv4.tcp_fin_timeout" bash "$ENTRYPOINT"

    [ "$status" -ne 0 ]
    [[ "$output" == *"proxy-sysctls entries must be key=value (got: 'net.ipv4.tcp_fin_timeout')"* ]]
}

@test "entrypoint passes MTU and sysctls to docker and writes listen-port-base" {
    mkdir -p "$BATS_TEST_TMPDIR/bin"
    cat >"$BATS_TEST_TMPDIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
printf '%q ' "$@" >>"$DOCKER_LOG" && echo >>"$DOCKER_LOG"
[[ "$1 ${2-}" == "inspect -f" ]] && echo 10.0.0.2
[[ "$1 ${2-} ${3-}" != "network inspect discovery-client-net" ]]
STUB
    printf '#!/usr/bin/env bash\n' >"$BATS_TEST_TMPDIR/bin/curl"
    chmod +x "$BATS_TEST_TMPDIR/bin/docker" "$BATS_TEST_TMPDIR/bin/curl"

    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" \
        CONTAINER_NAMES="aerospike-1" AEROSPIKE_NETWORK_NAME="aerospike-net" LISTEN_PORT_BASE="31001" CLIENT_NETWORK_MTU="1280" \
        PROXY_SYSCTLS="net.ipv4.ip_local_port_range=40000 40010, net.core.somaxconn=1024" bash "$ENTRYPOINT"

    [ "$status" -eq 0 ]
    grep -qxF 'network create --opt com.docker.network.driver.mtu=1280 discovery-client-net ' "$BATS_TEST_TMPDIR/docker.log"
    grep -qF 'aerospike-net --sysctl net.ipv4.ip_local_port_range=40000\ 40010 --sysctl net.core.somaxconn=1024 ghcr.io' "$BATS_TEST_TMPDIR/docker.log"
    grep -qx 'listen-port-base=31001' "$BATS_TEST_TMPDIR/out"
    [[ $(<"$BATS_TEST_TMPDIR/out") != *endpoint-port-base=* ]]
}
