#!/usr/bin/env bats
# setup-dns-server tests against a stub docker binary.

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/setup-dns-server"
ENTRYPOINT="$ACTION_DIR/entrypoint.sh"

bats_require_minimum_version 1.5.0

ZONE="\$ORIGIN dns.test.
@ 3600 IN SOA ns.dns.test. admin.dns.test. 1 60 60 60 1
seeds 1 IN A 192.0.2.10"

setup() {
    STUB_DIR="$BATS_TEST_TMPDIR/bin"
    DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
    COPY_DIR="$BATS_TEST_TMPDIR/copied"
    GITHUB_OUTPUT_FILE="$BATS_TEST_TMPDIR/github_output"
    mkdir -p "$STUB_DIR"
    : >"$DOCKER_LOG"
    : >"$GITHUB_OUTPUT_FILE"

    cat >"$STUB_DIR/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$DOCKER_LOG"
case "$1" in
network)
    [[ $STUB_NETWORK_EXISTS == "true" ]]
    ;;
inspect)
    if [[ $2 == "-f" ]]; then
        if [[ $3 == *State.Running* ]]; then
            echo "$STUB_RUNNING"
        else
            echo "10.0.0.53"
        fi
    else
        [[ $STUB_CONTAINER_EXISTS == "true" ]]
    fi
    ;;
cp)
    mkdir -p "$COPY_DIR"
    cp -R "$2" "$COPY_DIR/"
    ;;
run)
    [[ $STUB_PROBE_OK == "true" ]]
    ;;
logs)
    echo "stub coredns log"
    ;;
esac
STUB
    chmod +x "$STUB_DIR/docker"
}

run_entrypoint() {
    run env \
        PATH="$STUB_DIR:$PATH" \
        DOCKER_LOG="$DOCKER_LOG" \
        COPY_DIR="$COPY_DIR" \
        GITHUB_OUTPUT="$GITHUB_OUTPUT_FILE" \
        STUB_NETWORK_EXISTS=true \
        STUB_CONTAINER_EXISTS=false \
        STUB_RUNNING=true \
        STUB_PROBE_OK=true \
        NETWORK_NAME="dns-net" \
        ZONE_CONTENT="$ZONE" \
        ZONE_NAME="dns.test." \
        "$@" \
        bash "$ENTRYPOINT"
}

@test "entrypoint fails when the Docker network does not exist" {
    run_entrypoint STUB_NETWORK_EXISTS=false

    [ "$status" -ne 0 ]
    [[ "$output" == *"Docker network 'dns-net' does not exist"* ]]
    run ! grep -q "^create" "$DOCKER_LOG"
}

@test "entrypoint fails when the container already exists" {
    run_entrypoint STUB_CONTAINER_EXISTS=true

    [ "$status" -ne 0 ]
    [[ "$output" == *"container 'coredns' already exists"* ]]
    run ! grep -q "^create" "$DOCKER_LOG"
}

@test "entrypoint copies the Corefile and zone file and writes outputs" {
    run_entrypoint CONTAINER_NAME=dns-1

    [ "$status" -eq 0 ]
    grep -qxF "create --name dns-1 --network dns-net docker.io/coredns/coredns@sha256:9caabbf6238b189a65d0d6e6ac138de60d6a1c419e5a341fbbb7c78382559c6e -conf /etc/coredns/Corefile" "$DOCKER_LOG"
    grep -qE "^cp .*/\. dns-1:/etc/coredns/$" "$DOCKER_LOG"
    grep -qxF "start dns-1" "$DOCKER_LOG"
    grep -qxF "run --rm --network dns-net docker.io/library/busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e nslookup -type=soa dns.test 10.0.0.53" "$DOCKER_LOG"

    [ "$(cat "$COPY_DIR/Corefile")" = "dns.test:53 {
    file /etc/coredns/db.dns.test {
        reload 1s
    }
    errors
    log
}" ]
    [ "$(cat "$COPY_DIR/db.dns.test")" = "$ZONE" ]

    grep -qxF "server-address=10.0.0.53" "$GITHUB_OUTPUT_FILE"
    grep -qxF "container-name=dns-1" "$GITHUB_OUTPUT_FILE"
}

@test "entrypoint uses coredns-image when set" {
    run_entrypoint COREDNS_IMAGE="coredns/coredns:1.12.0"

    [ "$status" -eq 0 ]
    grep -qxF "pull coredns/coredns:1.12.0" "$DOCKER_LOG"
    grep -qxF "create --name coredns --network dns-net coredns/coredns:1.12.0 -conf /etc/coredns/Corefile" "$DOCKER_LOG"
}

@test "entrypoint prints the container log when the SOA query never succeeds" {
    run_entrypoint STUB_PROBE_OK=false STARTUP_TIMEOUT=1

    [ "$status" -ne 0 ]
    [[ "$output" == *"did not answer SOA dns.test within 1s"* ]]
    [[ "$output" == *"stub coredns log"* ]]
    [[ "$output" == *"DNS server for zone 'dns.test' did not become ready"* ]]
    [ ! -s "$GITHUB_OUTPUT_FILE" ]
}

@test "entrypoint prints the container log when CoreDNS exits" {
    run_entrypoint STUB_RUNNING=false

    [ "$status" -ne 0 ]
    [[ "$output" == *"coredns is not running"* ]]
    [[ "$output" == *"stub coredns log"* ]]
    [ ! -s "$GITHUB_OUTPUT_FILE" ]
}
