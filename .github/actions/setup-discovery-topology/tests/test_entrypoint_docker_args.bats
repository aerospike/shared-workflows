#!/usr/bin/env bats
# Docker argument tests for setup-discovery-topology using stub docker and curl binaries.

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/setup-discovery-topology"
ENTRYPOINT="$ACTION_DIR/entrypoint.sh"

setup() {
    STUB_DIR="$BATS_TEST_TMPDIR/bin"
    DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
    GITHUB_OUTPUT_FILE="$BATS_TEST_TMPDIR/github_output"
    mkdir -p "$STUB_DIR"
    : >"$DOCKER_LOG"
    : >"$GITHUB_OUTPUT_FILE"

    cat >"$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
case "$1 ${2-}" in
"network inspect")
    [[ $3 != "discovery-client-net" ]]
    ;;
"inspect -f")
    echo "10.0.0.2"
    ;;
esac
STUB
    printf '#!/usr/bin/env bash\nexit 0\n' >"$STUB_DIR/curl"
    chmod +x "$STUB_DIR/docker" "$STUB_DIR/curl"
}

run_entrypoint() {
    run env \
        PATH="$STUB_DIR:$PATH" \
        DOCKER_LOG="$DOCKER_LOG" \
        GITHUB_OUTPUT="$GITHUB_OUTPUT_FILE" \
        CONTAINER_NAMES="aerospike-1,aerospike-2" \
        AEROSPIKE_NETWORK_NAME="aerospike-net" \
        "$@" \
        bash "$ENTRYPOINT"
}

@test "without the new inputs, network create and proxy run arguments are unchanged" {
    run_entrypoint

    [ "$status" -eq 0 ]
    grep -qxF "network create discovery-client-net" "$DOCKER_LOG"
    grep -qxF "run --name toxiproxy --detach --network aerospike-net ghcr.io/shopify/toxiproxy:2.12.0 -host=0.0.0.0 -port=8474" "$DOCKER_LOG"
}

@test "client-network-mtu adds the bridge MTU option to network create" {
    run_entrypoint CLIENT_NETWORK_MTU=1280

    [ "$status" -eq 0 ]
    grep -qxF "network create --opt com.docker.network.driver.mtu=1280 discovery-client-net" "$DOCKER_LOG"
    grep -qxF "run --name toxiproxy --detach --network aerospike-net ghcr.io/shopify/toxiproxy:2.12.0 -host=0.0.0.0 -port=8474" "$DOCKER_LOG"
}

@test "proxy-sysctls adds one --sysctl per entry to the proxy run" {
    run_entrypoint PROXY_SYSCTLS="net.ipv4.ip_local_port_range=40000 40010, net.core.somaxconn=1024"

    [ "$status" -eq 0 ]
    grep -qxF "network create discovery-client-net" "$DOCKER_LOG"
    grep -qxF "run --name toxiproxy --detach --network aerospike-net --sysctl net.ipv4.ip_local_port_range=40000 40010 --sysctl net.core.somaxconn=1024 ghcr.io/shopify/toxiproxy:2.12.0 -host=0.0.0.0 -port=8474" "$DOCKER_LOG"
}

@test "proxy-sysctls keeps a value with a space as a single argument" {
    cat >>"$STUB_DIR/docker" <<'STUB'
if [[ $1 == "run" ]]; then
    printf 'arg:%s\n' "$@" >>"$DOCKER_LOG"
fi
STUB
    run_entrypoint PROXY_SYSCTLS="net.ipv4.ip_local_port_range=40000 40010"

    [ "$status" -eq 0 ]
    grep -qxF "arg:--sysctl" "$DOCKER_LOG"
    grep -qxF "arg:net.ipv4.ip_local_port_range=40000 40010" "$DOCKER_LOG"
}

@test "entrypoint writes listen-port-base" {
    run_entrypoint LISTEN_PORT_BASE=31001

    [ "$status" -eq 0 ]
    grep -qxF "listen-port-base=31001" "$GITHUB_OUTPUT_FILE"
    [ "$(grep -c "port-base=" "$GITHUB_OUTPUT_FILE")" -eq 1 ]
}
