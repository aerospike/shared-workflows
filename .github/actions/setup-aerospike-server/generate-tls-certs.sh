#!/usr/bin/env bash
# Generate the test CA, server cert, and client cert used by setup-aerospike-server.
#
# The server config tls-name stays aerospike-tls. Callers choose whether that
# name is the certificate CN, a DNS SAN, or both:
#   both (default):  --cn aerospike-tls --include-tls-name-san true
#   SAN only (N-6):  --cn not-the-tls-name --include-tls-name-san true
#   CN only (N-17):  --cn aerospike-tls --include-tls-name-san false
set -euo pipefail

if [[ ${ENABLE_BASH_TRACE_MODE-} == "true" ]]; then
    set -x
fi

error() {
    echo "Error: $1" >&2
    exit 1
}

show_help() {
    cat <<'EOF'
Usage: generate-tls-certs.sh --out-dir DIR --num-nodes N --name-prefix PREFIX --cn CN --tls-name NAME --include-tls-name-san true|false [--key-bits N]

Write ca.crt, ca.key, server.crt, server.key, client.crt, and client.key into DIR.

--tls-name is the server config tls-name. --include-tls-name-san controls whether that
name is also a DNS SAN. --cn is independent, so a test can put the tls-name
only in the CN or only in the SANs. Container names, localhost, docker, and
127.0.0.1 are always SANs.

--key-bits defaults to 4096. Tests may pass a smaller size.
EOF
}

is_dns_name() {
    local value=$1
    [[ $value =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]
}

require_option_value() {
    local option=$1
    if [[ $# -lt 2 || -z ${2-} || $2 == -* ]]; then
        error "$option requires a value"
    fi
}

write_server_san_ext() {
    local dest=$1
    local tls_name=$2
    local include_tls_name_san=$3
    local num_nodes=$4
    local name_prefix=$5
    local dns_idx=1
    local i

    {
        echo "[v3_req]"
        echo "subjectAltName = @alt_names"
        echo "[alt_names]"
        if [[ $include_tls_name_san == "true" ]]; then
            echo "DNS.${dns_idx} = ${tls_name}"
            dns_idx=$((dns_idx + 1))
        fi
        for ((i = 1; i <= num_nodes; i++)); do
            echo "DNS.${dns_idx} = ${name_prefix}-${i}"
            dns_idx=$((dns_idx + 1))
        done
        echo "DNS.${dns_idx} = localhost"
        dns_idx=$((dns_idx + 1))
        echo "DNS.${dns_idx} = docker"
        echo "IP.1 = 127.0.0.1"
    } >"$dest"
}

main() {
    local out_dir=""
    local num_nodes=""
    local name_prefix=""
    local cn=""
    local tls_name=""
    local include_tls_name_san=""
    local key_bits="4096"

    while [[ $# -gt 0 ]]; do
        case $1 in
        --help | -h)
            show_help
            exit 0
            ;;
        --out-dir)
            require_option_value "$@"
            out_dir=$2
            shift 2
            ;;
        --num-nodes)
            require_option_value "$@"
            num_nodes=$2
            shift 2
            ;;
        --name-prefix)
            require_option_value "$@"
            name_prefix=$2
            shift 2
            ;;
        --cn)
            require_option_value "$@"
            cn=$2
            shift 2
            ;;
        --tls-name)
            require_option_value "$@"
            tls_name=$2
            shift 2
            ;;
        --include-tls-name-san)
            require_option_value "$@"
            include_tls_name_san=$2
            shift 2
            ;;
        --key-bits)
            require_option_value "$@"
            key_bits=$2
            shift 2
            ;;
        *)
            error "unknown option: $1"
            ;;
        esac
    done

    [[ -n $out_dir ]] || error "--out-dir is required"
    [[ -n $num_nodes ]] || error "--num-nodes is required"
    [[ -n $name_prefix ]] || error "--name-prefix is required"
    [[ -n $cn ]] || error "--cn is required"
    [[ -n $tls_name ]] || error "--tls-name is required"
    [[ -n $include_tls_name_san ]] || error "--include-tls-name-san is required"

    [[ $num_nodes =~ ^[1-9][0-9]*$ ]] || error "--num-nodes must be a positive integer (got: '$num_nodes')"
    [[ $key_bits =~ ^[1-9][0-9]*$ ]] || error "--key-bits must be a positive integer (got: '$key_bits')"
    [[ $include_tls_name_san == "true" || $include_tls_name_san == "false" ]] ||
        error "--include-tls-name-san must be 'true' or 'false' (got: '$include_tls_name_san')"
    is_dns_name "$cn" || error "--cn must be a DNS name (got: '$cn')"
    is_dns_name "$tls_name" || error "--tls-name must be a DNS name (got: '$tls_name')"
    [[ $name_prefix != *[[:space:]/]* ]] || error "--name-prefix must not contain whitespace or '/'"

    mkdir -p "$out_dir"

    local san_ext="$out_dir/san.ext"

    openssl req -x509 -newkey "rsa:${key_bits}" -nodes \
        -keyout "$out_dir/ca.key" -out "$out_dir/ca.crt" -days 365 \
        -subj "/CN=Aerospike-Server-Test-CA"

    write_server_san_ext "$san_ext" "$tls_name" "$include_tls_name_san" "$num_nodes" "$name_prefix"

    openssl req -newkey "rsa:${key_bits}" -nodes \
        -keyout "$out_dir/server.key" -out "$out_dir/server.csr" \
        -subj "/CN=${cn}"
    openssl x509 -req -in "$out_dir/server.csr" \
        -CA "$out_dir/ca.crt" -CAkey "$out_dir/ca.key" -CAcreateserial \
        -out "$out_dir/server.crt" -days 365 \
        -extensions v3_req -extfile "$san_ext"

    # A client cert with no extensions is X.509 v1. rustls rejects that
    # (UnsupportedCertVersion). basicConstraints forces v3; clientAuth
    # marks the purpose. Neither extension is critical.
    {
        echo "[client_cert]"
        echo "basicConstraints = CA:FALSE"
        echo "extendedKeyUsage = clientAuth"
    } >>"$san_ext"

    openssl req -newkey "rsa:${key_bits}" -nodes \
        -keyout "$out_dir/client.key" -out "$out_dir/client.csr" \
        -subj "/CN=Aerospike-Server-Test-Client"
    openssl x509 -req -in "$out_dir/client.csr" \
        -CA "$out_dir/ca.crt" -CAkey "$out_dir/ca.key" -CAcreateserial \
        -out "$out_dir/client.crt" -days 365 \
        -extensions client_cert -extfile "$san_ext"

    rm -f "$out_dir"/*.csr "$out_dir"/*.srl "$san_ext"
}

main "$@"
