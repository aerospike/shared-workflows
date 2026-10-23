#!/usr/bin/env bats
# Tests for per-node config rendering and docker run arguments in start-containers.sh.
#
# fixtures/baseline holds the config file and docker run arguments produced by
# the start-containers step before per-node rendering, with the random
# --config-file value replaced by <config-file>.

bats_require_minimum_version 1.5.0

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/setup-aerospike-server"
START="$ACTION_DIR/start-containers.sh"
FIXTURES="$ACTION_DIR/tests/fixtures"

# shellcheck source=/dev/null
source "$ACTION_DIR/config-helpers.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export TEST_TMPDIR
    export DOCKER_STUB_DIR="$TEST_TMPDIR/docker"
    export GITHUB_OUTPUT="$TEST_TMPDIR/github-output"
    mkdir -p "$TEST_TMPDIR/bin" "$DOCKER_STUB_DIR/cp"
    cat >"$TEST_TMPDIR/bin/docker" <<'EOF'
#!/usr/bin/env bash
case $1 in
cp)
    cp "$2" "$DOCKER_STUB_DIR/cp/$(basename "$2")"
    ;;
run)
    shift
    count=$(($(cat "$DOCKER_STUB_DIR/run-count" 2>/dev/null || echo 0) + 1))
    echo "$count" >"$DOCKER_STUB_DIR/run-count"
    printf '%s\n' "$@" >"$DOCKER_STUB_DIR/run-$count.args"
    ;;
create)
    shift
    count=$(($(cat "$DOCKER_STUB_DIR/create-count" 2>/dev/null || echo 0) + 1))
    echo "$count" >"$DOCKER_STUB_DIR/create-count"
    printf '%s\n' "$@" >"$DOCKER_STUB_DIR/create-$count.args"
    ;;
inspect)
    cat "$DOCKER_STUB_DIR/address-${!#}" 2>/dev/null || true
    ;;
esac
EOF
    chmod +x "$TEST_TMPDIR/bin/docker"
    PATH="$TEST_TMPDIR/bin:$PATH"
}

teardown() {
    if [[ -n ${TEST_TMPDIR-} && -d $TEST_TMPDIR ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

start_containers() {
    local num_nodes=$1
    local edition=$2
    local features_path=$3
    local config_path=$4
    shift 4
    local repo=database-docker-virtual/aerospike-server-enterprise
    [[ $edition == "community" ]] && repo=database-docker-virtual/aerospike-server

    "$START" \
        --num-nodes "$num_nodes" \
        --base-port 3000 \
        --container-name-prefix aerospike \
        --service-port 3000 \
        --image "aerospike.jfrog.io/$repo:latest" \
        --network aerospike-net \
        --features-path "$features_path" \
        --config-path "$config_path" \
        --publish-ports true \
        --tls-base-port 4333 \
        --server-edition "$edition" \
        --conf-volume-name server_volume_1_1 \
        --conf-volume-dest-dir /etc/aerospike-custom \
        --tls-volume-name tls_server_volume_1_1 \
        --tls-volume-dest-dir /etc/aerospike/tls \
        --loader-container container_to_load_volume_1_1 \
        "$@"
}

normalized_args() {
    awk 'prev == "--config-file" { print "<config-file>"; prev = ""; next } { print; prev = $0 }' "$1"
}

with_ip() {
    awk -v ip="$1" '{ print } $0 == "aerospike-net" { print "--ip"; print ip }'
}

config_file_arg() {
    awk 'prev == "--config-file" { print } { prev = $0 }' "$DOCKER_STUB_DIR/run-$1.args"
}

node_config() {
    printf '%s\n' "$DOCKER_STUB_DIR/cp/aerospike-$1.conf"
}

custom_config() {
    local config_path="$TEST_TMPDIR/config-content"
    printf '%s' "$1" >"$config_path"
    printf '%s\n' "$config_path"
}

assert_matches_baseline() {
    local scenario=$1
    local num_nodes=$2
    local baseline="$FIXTURES/baseline/$scenario"
    local i

    [ "$(cat "$DOCKER_STUB_DIR/run-count")" -eq "$num_nodes" ]
    for ((i = 1; i <= num_nodes; i++)); do
        awk 'prev == "--config-file" { print "<config-file>"; prev = ""; next } { print; prev = $0 }' \
            "$DOCKER_STUB_DIR/run-$i.args" >"$TEST_TMPDIR/run-$i.args"
        diff -u "$baseline/docker-run-$i.args" "$TEST_TMPDIR/run-$i.args"
        if [[ -f "$baseline/aerospike.conf" ]]; then
            [ "$(config_file_arg "$i")" = "/etc/aerospike-custom/aerospike-$i.conf" ]
            cmp "$baseline/aerospike.conf" "$(node_config "$i")"
        else
            [ -z "$(config_file_arg "$i")" ]
        fi
    done
    if [[ ! -f "$baseline/aerospike.conf" ]]; then
        [ -z "$(ls -A "$DOCKER_STUB_DIR/cp")" ]
    fi
    diff -u "$baseline/github-output" <(grep -v '^node-addresses=' "$GITHUB_OUTPUT")
}

@test "default single node matches the baseline" {
    run start_containers 1 enterprise "" ""
    [ "$status" -eq 0 ]

    assert_matches_baseline single-node 1
}

@test "default multi-node matches the baseline" {
    run start_containers 3 enterprise "$FIXTURES/features.conf" ""
    [ "$status" -eq 0 ]

    assert_matches_baseline multi-node 3
}

@test "multi-node with enable-tls matches the baseline" {
    run start_containers 3 enterprise "$FIXTURES/features.conf" "" --enable-tls true
    [ "$status" -eq 0 ]

    assert_matches_baseline multi-node-tls 3
}

@test "multi-node with enable-security matches the baseline" {
    run start_containers 3 enterprise "$FIXTURES/features.conf" "" --security true
    [ "$status" -eq 0 ]

    assert_matches_baseline multi-node-security 3
}

@test "multi-node with enable-strong-consistency matches the baseline" {
    run start_containers 3 enterprise "$FIXTURES/features.conf" "" --enable-sc true
    [ "$status" -eq 0 ]

    assert_matches_baseline multi-node-strong-consistency 3
}

@test "multi-node with config-content matches the baseline" {
    config_path="$TEST_TMPDIR/config-content"
    cp "$FIXTURES/config-content.conf" "$config_path"

    run start_containers 3 enterprise "$FIXTURES/features.conf" "$config_path"
    [ "$status" -eq 0 ]

    assert_matches_baseline multi-node-config-content 3
}

@test "single node with config-content matches the baseline" {
    config_path="$TEST_TMPDIR/config-content"
    cp "$FIXTURES/config-content.conf" "$config_path"

    run start_containers 1 enterprise "" "$config_path"
    [ "$status" -eq 0 ]

    assert_matches_baseline single-node-config-content 1
}

@test "community multi-node with env-vars matches the baseline" {
    ENV_VARS='A=1;B=x\;y' run start_containers 2 community "" ""
    [ "$status" -eq 0 ]

    assert_matches_baseline community-multi-node-env-vars 2
}

@test "custom config renders NODE_INDEX and NODE_NAME per node" {
    config_path=$(custom_config $'network {\n    service {\n        port 3000\n        alternate-access-port 50{{NODE_INDEX}}0\n        alternate-access-address {{NODE_NAME}}\n    }\n    heartbeat {\n        mode mesh\n        port 3002\n    }\n}\n# node {{NODE_INDEX}} is {{NODE_NAME}}\n')

    run start_containers 3 community "" "$config_path"
    [ "$status" -eq 0 ]

    for i in 1 2 3; do
        conf=$(node_config "$i")
        [ "$(config_file_arg "$i")" = "/etc/aerospike-custom/aerospike-$i.conf" ]
        grep -qx "        alternate-access-port 50${i}0" "$conf"
        grep -qx "        alternate-access-address aerospike-$i" "$conf"
        grep -qx "# node $i is aerospike-$i" "$conf"
        grep -qx "        mesh-seed-address-port aerospike-3 3002" "$conf"
        run grep -q '{{NODE_' "$conf"
        [ "$status" -ne 0 ]
    done
}

@test "custom config writes command substitutions and variables literally" {
    marker="$TEST_TMPDIR/executed"
    export SECRET_VALUE=expanded
    config_path=$(custom_config "service {
    cluster-name \$(touch $marker)
    work-directory \${SECRET_VALUE}
    pidfile \`touch $marker\`
    node-id-interface {{NODE_NAME}}
}
")

    run start_containers 2 community "" "$config_path"
    [ "$status" -eq 0 ]

    [ ! -e "$marker" ]
    for i in 1 2; do
        conf=$(node_config "$i")
        grep -qxF "    cluster-name \$(touch $marker)" "$conf"
        grep -qxF "    work-directory \${SECRET_VALUE}" "$conf"
        grep -qxF "    pidfile \`touch $marker\`" "$conf"
        grep -qxF "    node-id-interface aerospike-$i" "$conf"
        run grep -q expanded "$conf"
        [ "$status" -ne 0 ]
    done
}

@test "extra-hosts adds --add-host to every node" {
    EXTRA_HOSTS="db.example:10.0.0.5, gateway:host-gateway" run start_containers 3 community "" ""
    [ "$status" -eq 0 ]

    for i in 1 2 3; do
        grep -A1 -x -- "--add-host" "$DOCKER_STUB_DIR/run-$i.args" >"$TEST_TMPDIR/hosts"
        printf '%s\n' --add-host db.example:10.0.0.5 --add-host gateway:host-gateway | diff -u - "$TEST_TMPDIR/hosts"
    done
}

@test "invalid extra-hosts fails before starting containers" {
    EXTRA_HOSTS="db.example=10.0.0.5" run --separate-stderr start_containers 2 community "" ""
    [ "$status" -ne 0 ]
    [[ $stderr == *"extra-hosts entries must be name:ip"* ]]
    [ ! -e "$DOCKER_STUB_DIR/run-count" ]
}

@test "parse_extra_hosts accepts IPv4, IPv6 and host-gateway" {
    run parse_extra_hosts " a.example:10.0.0.1, b:::1 ,c:host-gateway,"

    [ "$status" -eq 0 ]
    [ "$output" = $'a.example:10.0.0.1\nb:::1\nc:host-gateway' ]
}

@test "parse_extra_hosts rejects malformed entries" {
    # shellcheck disable=SC2016
    for entry in "nohost" "a:" ":10.0.0.1" "a:10.0.0" "a:not-an-ip" "-a:10.0.0.1" 'a:$(id)'; do
        run --separate-stderr parse_extra_hosts "ok:10.0.0.1,$entry"
        [ "$status" -ne 0 ]
        [[ $stderr == *"extra-hosts entries must be name:ip"* ]]
    done
}

@test "render_node_config keeps trailing newlines" {
    printf 'a {{NODE_INDEX}}\n\n\n' >"$TEST_TMPDIR/in.conf"

    render_node_config "$TEST_TMPDIR/in.conf" "$TEST_TMPDIR/out.conf" 2 aerospike-2

    cmp <(printf 'a 2\n\n\n') "$TEST_TMPDIR/out.conf"
}

@test "empty start-nodes and network-subnet match the baseline" {
    run start_containers 3 enterprise "$FIXTURES/features.conf" "" --start-nodes "" --network-subnet ""
    [ "$status" -eq 0 ]

    assert_matches_baseline multi-node 3
    [ ! -e "$DOCKER_STUB_DIR/create-count" ]
}

@test "start-nodes equal to num-nodes matches the baseline" {
    run start_containers 3 enterprise "$FIXTURES/features.conf" "" --start-nodes 3
    [ "$status" -eq 0 ]

    assert_matches_baseline multi-node 3
    [ ! -e "$DOCKER_STUB_DIR/create-count" ]
}

@test "start-nodes runs the first nodes and creates the rest without --detach" {
    run start_containers 3 enterprise "$FIXTURES/features.conf" "" --start-nodes 1
    [ "$status" -eq 0 ]

    [ "$(cat "$DOCKER_STUB_DIR/run-count")" -eq 1 ]
    [ "$(cat "$DOCKER_STUB_DIR/create-count")" -eq 2 ]
    diff -u "$FIXTURES/baseline/multi-node/docker-run-1.args" <(normalized_args "$DOCKER_STUB_DIR/run-1.args")
    for i in 2 3; do
        diff -u <(grep -vx -- --detach "$FIXTURES/baseline/multi-node/docker-run-$i.args") \
            <(normalized_args "$DOCKER_STUB_DIR/create-$((i - 1)).args")
        cmp "$FIXTURES/baseline/multi-node/aerospike.conf" "$(node_config "$i")"
    done
    [[ $output == *"Creating (not started) container: aerospike-3 (host port: 3002)"* ]]
    diff -u "$FIXTURES/baseline/multi-node/github-output" <(grep -v '^node-addresses=' "$GITHUB_OUTPUT")
}

@test "start-nodes keeps every node in the mesh seed list" {
    run start_containers 3 community "" "" --start-nodes 1
    [ "$status" -eq 0 ]

    for i in 1 2 3; do
        for j in 1 2 3; do
            grep -qx "        mesh-seed-address-port aerospike-$j 3002" "$(node_config "$i")"
        done
    done
}

@test "invalid start-nodes fails before starting containers" {
    for start_nodes in 0 4 abc -1; do
        run --separate-stderr start_containers 3 community "" "" --start-nodes "$start_nodes"
        [ "$status" -ne 0 ]
        [[ $stderr == *"start-nodes must be between 1 and num-nodes (3)"* ]]
        [ ! -e "$DOCKER_STUB_DIR/run-count" ]
        [ ! -e "$DOCKER_STUB_DIR/create-count" ]
    done
}

@test "network-subnet adds a fixed --ip after --network for every node" {
    run start_containers 3 enterprise "$FIXTURES/features.conf" "" --network-subnet 172.30.0.0/24 --start-nodes 2
    [ "$status" -eq 0 ]

    for i in 1 2; do
        diff -u <(with_ip "172.30.0.$((i + 1))" <"$FIXTURES/baseline/multi-node/docker-run-$i.args") \
            <(normalized_args "$DOCKER_STUB_DIR/run-$i.args")
    done
    diff -u <(grep -vx -- --detach "$FIXTURES/baseline/multi-node/docker-run-3.args" | with_ip 172.30.0.4) \
        <(normalized_args "$DOCKER_STUB_DIR/create-1.args")
    grep -qx node-addresses=172.30.0.2,172.30.0.3,172.30.0.4 "$GITHUB_OUTPUT"
}

@test "node-addresses lists inspected IPs in node order, empty for unstarted nodes" {
    echo 10.89.0.3 >"$DOCKER_STUB_DIR/address-aerospike-1"
    echo 10.89.0.2 >"$DOCKER_STUB_DIR/address-aerospike-2"
    echo "invalid IP" >"$DOCKER_STUB_DIR/address-aerospike-3"

    run start_containers 3 community "" "" --start-nodes 2
    [ "$status" -eq 0 ]

    grep -qx node-addresses=10.89.0.3,10.89.0.2, "$GITHUB_OUTPUT"
}

@test "invalid network-subnet fails before starting containers" {
    run --separate-stderr start_containers 3 community "" "" --network-subnet 172.30.0.1/24
    [ "$status" -ne 0 ]
    [[ $stderr == *"has host bits set"* ]]
    [ ! -e "$DOCKER_STUB_DIR/run-count" ]
}
