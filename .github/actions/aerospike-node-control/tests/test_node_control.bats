#!/usr/bin/env bats
# Tests for the request handling in node-control.sh. Starting and removing
# real nodes is covered by test_setup-aerospike-server.yaml.

bats_require_minimum_version 1.5.0

GIT_ROOT="$(git rev-parse --show-toplevel)"
NODE_CONTROL="$GIT_ROOT/.github/actions/aerospike-node-control/node-control.sh"

setup() {
    # shellcheck source=/dev/null
    source "$NODE_CONTROL"
    dir="$(mktemp -d)"
}

teardown() {
    rm -rf "$dir"
}

@test "start with no options sets no IP or alternate port" {
    parse_start_options ""
    [[ -z $start_ip && -z $start_alternate_port && -z $start_error ]]
}

@test "start options set the IP and the alternate port" {
    alternate_address=as-endpoint.test
    parse_start_options "address=172.30.0.20 alternate-port=30005"
    [[ $start_ip == "172.30.0.20" && $start_alternate_port == "30005" ]]
}

@test "alternate-port without alternate-access-address is an error" {
    local rc=0
    alternate_address=""
    parse_start_options "alternate-port=30005" || rc=$?
    [[ $rc -ne 0 && $start_error == *"needs the alternate-access-address input"* ]]
}

@test "invalid start options are errors" {
    alternate_address=as-endpoint.test
    parse_start_options "address=host.test" || true
    [[ $start_error == *"is not an IPv4 address"* ]]
    parse_start_options "alternate-port=x" || true
    [[ $start_error == *"is not a port"* ]]
    parse_start_options "replicas=2" || true
    [[ $start_error == *"unknown start option replicas=2"* ]]
}

@test "ack writes the acknowledgement and leaves no temporary file" {
    ack request-1 $'container=aerospike-5\naddress=172.30.0.6'
    [[ $(cat "$dir/request-1.ack") == $'container=aerospike-5\naddress=172.30.0.6' ]]
    [[ ! -e "$dir/request-1.tmp" ]]
}

@test "a missing control directory or invalid template index fails before serving" {
    run "$NODE_CONTROL" --control-dir "$dir/missing" --template-node-index 4
    [[ $status -eq 1 && $output == *"control directory"*"does not exist"* ]]
    run "$NODE_CONTROL" --control-dir "$dir" --template-node-index 0
    [[ $status -eq 1 && $output == *"template-node-index must be a positive integer"* ]]
    run "$NODE_CONTROL" --control-dir "$dir" --replicas 2
    [[ $status -eq 1 && $output == *"Unknown option: --replicas"* ]]
}
