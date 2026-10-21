#!/usr/bin/env bats
# Tests for node-control.sh with a docker stub. Container state lives in
# $DOCKER_STUB_DIR/state-<name> (running or created); asinfo calls are logged.

bats_require_minimum_version 1.5.0

GIT_ROOT="$(git rev-parse --show-toplevel)"
NODE_CONTROL="$GIT_ROOT/.github/actions/aerospike-node-control/node-control.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export TEST_TMPDIR
    export DOCKER_STUB_DIR="$TEST_TMPDIR/docker"
    export GITHUB_OUTPUT="$TEST_TMPDIR/github-output"
    mkdir -p "$TEST_TMPDIR/bin" "$DOCKER_STUB_DIR"
    cat >"$TEST_TMPDIR/bin/docker" <<'STUB'
#!/usr/bin/env bash
case $1 in
inspect)
    name=${!#}
    state_file="$DOCKER_STUB_DIR/state-$name"
    [[ -f $state_file ]] || exit 1
    if [[ $3 == "{{.State.Running}}" ]]; then
        [[ $(cat "$state_file") == "running" ]] && echo true || echo false
    elif [[ $(cat "$state_file") == "running" ]]; then
        echo "10.89.0.${name##*-}"
    fi
    ;;
start | stop)
    echo "$1 $2" >>"$DOCKER_STUB_DIR/commands"
    [[ $1 == "start" ]] && echo running >"$DOCKER_STUB_DIR/state-$2" || echo exited >"$DOCKER_STUB_DIR/state-$2"
    echo "$2"
    ;;
ps)
    for state_file in "$DOCKER_STUB_DIR"/state-*; do
        [[ $(cat "$state_file") == "running" ]] && echo "${state_file##*/state-}"
    done
    echo aerospike-tools
    echo container_to_load_volume_1_1
    ;;
run)
    printf '%s\n' "${@: -1}" >>"$DOCKER_STUB_DIR/asinfo"
    echo ABCDEF
    ;;
esac
STUB
    chmod +x "$TEST_TMPDIR/bin/docker"
    PATH="$TEST_TMPDIR/bin:$PATH"
    echo running >"$DOCKER_STUB_DIR/state-aerospike-1"
    echo running >"$DOCKER_STUB_DIR/state-aerospike-2"
    echo created >"$DOCKER_STUB_DIR/state-aerospike-3"
}

teardown() {
    if [[ -n ${TEST_TMPDIR-} && -d $TEST_TMPDIR ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

node_control() {
    "$NODE_CONTROL" --container-name-prefix aerospike --network aerospike-net \
        --tools-image aerospike.jfrog.io/database-docker-virtual/aerospike-tools:12.1.1_2 "$@"
}

@test "start waits for every running node to see the larger cluster" {
    run node_control --node-index 3 --operation start
    [ "$status" -eq 0 ]

    [ "$(cat "$DOCKER_STUB_DIR/commands")" = "start aerospike-3" ]
    [ "$(sort -u "$DOCKER_STUB_DIR/asinfo")" = "cluster-stable:size=3;ignore-migrations=false" ]
    [ "$(wc -l <"$DOCKER_STUB_DIR/asinfo")" -eq 3 ]
    printf '%s\n' cluster-size=3 running-nodes=aerospike-1,aerospike-2,aerospike-3 node-address=10.89.0.3 |
        diff -u - "$GITHUB_OUTPUT"
}

@test "stop waits for the remaining nodes to see the smaller cluster" {
    run node_control --node-index 2 --operation stop --enable-sc true
    [ "$status" -eq 0 ]

    [ "$(cat "$DOCKER_STUB_DIR/commands")" = "stop aerospike-2" ]
    [ "$(cat "$DOCKER_STUB_DIR/asinfo")" = "cluster-stable:size=1;ignore-migrations=true" ]
    printf '%s\n' cluster-size=1 running-nodes=aerospike-1 node-address= | diff -u - "$GITHUB_OUTPUT"
}

@test "stopping the last running node skips the wait" {
    echo exited >"$DOCKER_STUB_DIR/state-aerospike-2"

    run node_control --node-index 1 --operation stop
    [ "$status" -eq 0 ]

    [ ! -e "$DOCKER_STUB_DIR/asinfo" ]
    grep -qx cluster-size=0 "$GITHUB_OUTPUT"
}

@test "starting a running node or stopping a stopped node fails" {
    run --separate-stderr node_control --node-index 1 --operation start
    [ "$status" -ne 0 ]
    [ "$stderr" = "Error: aerospike-1 is already running" ]

    run --separate-stderr node_control --node-index 3 --operation stop
    [ "$status" -ne 0 ]
    [ "$stderr" = "Error: aerospike-3 is not running" ]

    [ ! -e "$DOCKER_STUB_DIR/commands" ]
}

@test "invalid node-index, operation or missing container fails" {
    run --separate-stderr node_control --node-index 0 --operation start
    [ "$status" -ne 0 ]
    [[ $stderr == *"node-index must be a positive integer"* ]]

    run --separate-stderr node_control --node-index 1 --operation restart
    [ "$status" -ne 0 ]
    [[ $stderr == *"operation must be 'start' or 'stop'"* ]]

    run --separate-stderr node_control --node-index 4 --operation start
    [ "$status" -ne 0 ]
    [ "$stderr" = "Error: container aerospike-4 does not exist" ]

    [ ! -e "$DOCKER_STUB_DIR/commands" ]
}
