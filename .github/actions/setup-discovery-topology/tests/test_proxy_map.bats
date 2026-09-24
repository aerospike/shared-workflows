#!/usr/bin/env bats
# Tests for Toxiproxy port-map rendering.

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/setup-discovery-topology"

# shellcheck source=/dev/null
source "$ACTION_DIR/proxy_map.sh"

setup() {
    CONTAINER_NAME_LIST=()
}

@test "parses comma-separated container names and trims whitespace" {
    parse_container_names " aerospike-1, aerospike-2,aerospike-3 "

    [ "${#CONTAINER_NAME_LIST[@]}" -eq 3 ]
    [ "${CONTAINER_NAME_LIST[0]}" = "aerospike-1" ]
    [ "${CONTAINER_NAME_LIST[1]}" = "aerospike-2" ]
    [ "${CONTAINER_NAME_LIST[2]}" = "aerospike-3" ]
}

@test "rejects empty container-names" {
    run parse_container_names ""

    [ "$status" -ne 0 ]
    [[ "$output" == *"container-names is required"* ]]
}

@test "rejects empty names in the list" {
    run parse_container_names "aerospike-1,,aerospike-2"

    [ "$status" -ne 0 ]
    [[ "$output" == *"empty name"* ]]
}

@test "rejects duplicate container names" {
    run parse_container_names "aerospike-1,aerospike-1"

    [ "$status" -ne 0 ]
    [[ "$output" == *"duplicate container name"* ]]
}

@test "rejects invalid container names" {
    run parse_container_names "bad name"

    [ "$status" -ne 0 ]
    [[ "$output" == *"invalid container name"* ]]
}

@test "renders listen ports and upstreams for three nodes" {
    parse_container_names "aerospike-1,aerospike-2,aerospike-3"

    json=$(build_proxy_json 30001 3000)
    ports=$(build_listen_ports_csv 30001)
    map=$(build_name_port_csv 30001)

    [ "$ports" = "30001,30002,30003" ]
    [ "$map" = "aerospike-1:30001,aerospike-2:30002,aerospike-3:30003" ]
    [[ "$json" == *'"name":"aerospike-1"'* ]]
    [[ "$json" == *'"listen":"0.0.0.0:30001"'* ]]
    [[ "$json" == *'"upstream":"aerospike-1:3000"'* ]]
    [[ "$json" == *'"name":"aerospike-3"'* ]]
    [[ "$json" == *'"listen":"0.0.0.0:30003"'* ]]
    python3 -m json.tool <<<"$json" >/dev/null
}

@test "renders TLS proxy names with suffix" {
    parse_container_names "aerospike-1,aerospike-2"

    json=$(build_proxy_json 43331 4333 "-tls")
    map=$(build_name_port_csv 43331 "-tls")

    [ "$map" = "aerospike-1-tls:43331,aerospike-2-tls:43332" ]
    [[ "$json" == *'"name":"aerospike-1-tls"'* ]]
    [[ "$json" == *'"upstream":"aerospike-1:4333"'* ]]
    python3 -m json.tool <<<"$json" >/dev/null
}

@test "merges clear-text and TLS proxy JSON arrays" {
    parse_container_names "aerospike-1"
    clear_json=$(build_proxy_json 30001 3000)
    tls_json=$(build_proxy_json 43331 4333 "-tls")
    merged=$(merge_json_arrays "$clear_json" "$tls_json")

    [[ "$merged" == *'"name":"aerospike-1"'* ]]
    [[ "$merged" == *'"name":"aerospike-1-tls"'* ]]
    python3 -m json.tool <<<"$merged" >/dev/null
}

@test "merge_json_arrays is a no-op for an empty side" {
    [ "$(merge_json_arrays '[]' '[{"name":"a"}]')" = '[{"name":"a"}]' ]
    [ "$(merge_json_arrays '[{"name":"a"}]' '[]')" = '[{"name":"a"}]' ]
}

@test "rejects listen ports that overflow 65535" {
    parse_container_names "aerospike-1,aerospike-2"

    run validate_listen_range 65535

    [ "$status" -ne 0 ]
    [[ "$output" == *"exceed 65535"* ]]
}
