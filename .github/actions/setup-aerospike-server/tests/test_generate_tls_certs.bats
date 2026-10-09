#!/usr/bin/env bats
# Tests for setup-aerospike-server TLS certificate shapes.

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/setup-aerospike-server"
GENERATE="$ACTION_DIR/generate-tls-certs.sh"

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    export TEST_TMPDIR
}

teardown() {
    if [[ -n ${TEST_TMPDIR-} && -d $TEST_TMPDIR ]]; then
        rm -rf "$TEST_TMPDIR"
    fi
}

generate_certs() {
    "$GENERATE" \
        --out-dir "$TEST_TMPDIR/certs" \
        --key-bits 2048 \
        "$@"
}

server_subject() {
    local subject
    subject=$(openssl x509 -in "$TEST_TMPDIR/certs/server.crt" -noout -subject -nameopt RFC2253)
    printf '%s\n' "${subject#subject=}"
}

server_san() {
    openssl x509 -in "$TEST_TMPDIR/certs/server.crt" -noout -ext subjectAltName
}

assert_san_has() {
    local name=$1
    local san=$2
    echo "$san" | grep -Eq "(^|[[:space:],])${name}(,|$)"
}

assert_san_lacks() {
    local name=$1
    local san=$2
    if echo "$san" | grep -Eq "(^|[[:space:],])${name}(,|$)"; then
        echo "SAN unexpectedly contains ${name}: ${san}"
        return 1
    fi
}

@test "default cert has tls-name as both CN and DNS SAN" {
    generate_certs \
        --num-nodes 1 \
        --name-prefix aerospike \
        --cn aerospike-tls \
        --tls-name aerospike-tls \
        --include-tls-name-san true

    [[ $(server_subject) == "CN=aerospike-tls" ]]
    san=$(server_san)
    assert_san_has "DNS:aerospike-tls" "$san"
    assert_san_has "DNS:aerospike-1" "$san"
    assert_san_has "DNS:localhost" "$san"
    assert_san_has "DNS:docker" "$san"
    echo "$san" | grep -q '127.0.0.1'
    openssl x509 -in "$TEST_TMPDIR/certs/client.crt" -noout -text | grep -q "Version: 3"
    [[ ! -e "$TEST_TMPDIR/certs/san.ext" ]]
    [[ ! -e "$TEST_TMPDIR/certs/server.csr" ]]
}

@test "SAN-only tls-name keeps a CN that does not match" {
    generate_certs \
        --num-nodes 1 \
        --name-prefix aerospike \
        --cn not-the-tls-name \
        --tls-name aerospike-tls \
        --include-tls-name-san true

    [[ $(server_subject) == "CN=not-the-tls-name" ]]
    san=$(server_san)
    assert_san_has "DNS:aerospike-tls" "$san"
    assert_san_has "DNS:aerospike-1" "$san"
}

@test "CN-only tls-name omits that name from the SANs" {
    generate_certs \
        --num-nodes 2 \
        --name-prefix as \
        --cn aerospike-tls \
        --tls-name aerospike-tls \
        --include-tls-name-san false

    [[ $(server_subject) == "CN=aerospike-tls" ]]
    san=$(server_san)
    assert_san_lacks "DNS:aerospike-tls" "$san"
    assert_san_has "DNS:as-1" "$san"
    assert_san_has "DNS:as-2" "$san"
    assert_san_has "DNS:localhost" "$san"
    echo "$san" | grep -q '127.0.0.1'
}

@test "rejects a tls-name SAN flag that is not true or false" {
    run generate_certs \
        --num-nodes 1 \
        --name-prefix aerospike \
        --cn aerospike-tls \
        --tls-name aerospike-tls \
        --include-tls-name-san yes
    [ "$status" -ne 0 ]
}

@test "rejects a CN that is not a DNS name" {
    run generate_certs \
        --num-nodes 1 \
        --name-prefix aerospike \
        --cn "not a name" \
        --tls-name aerospike-tls \
        --include-tls-name-san true
    [ "$status" -ne 0 ]
}

@test "action wires cert shape inputs through to the generator" {
    grep -q 'tls-cert-cn:' "$ACTION_DIR/action.yaml"
    grep -q 'include-tls-name-san:' "$ACTION_DIR/action.yaml"
    grep -q -- '--cn "$TLS_CERT_CN"' "$ACTION_DIR/action.yaml"
    grep -q -- '--tls-name aerospike-tls' "$ACTION_DIR/action.yaml"
    grep -q -- '--include-tls-name-san "$INCLUDE_TLS_NAME_SAN"' "$ACTION_DIR/action.yaml"
}
