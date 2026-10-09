#!/usr/bin/env bash
set -euo pipefail

export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
trap 'handle_error ${LINENO}' ERR
# shellcheck disable=SC2317
handle_error() {
    local exit_code=$?
    local line_number=$1
    echo "Error: Command failed with exit code $exit_code at line $line_number" >&2
    if [[ -n ${PROXY_CONTAINER_NAME-} ]] && docker inspect "$PROXY_CONTAINER_NAME" >/dev/null 2>&1; then
        echo "Toxiproxy logs:" >&2
        docker logs "$PROXY_CONTAINER_NAME" >&2 || true
    fi
    exit "$exit_code"
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/proxy_map.sh"

show_help() {
    echo "Usage: $0 [OPTIONS]" >&2
    echo "" >&2
    echo "Create the L2 discovery topology: a client-only Docker network and a" >&2
    echo "Toxiproxy L4 proxy attached to both that network and the Aerospike network." >&2
    echo "Callers start their own client with docker run --network <client-network-name>." >&2
    echo "" >&2
    echo "Inputs are read from environment variables (set by action.yaml)." >&2
    echo "  --help, -h    Show this help message" >&2
}

validate_hostname() {
    local value=$1
    [[ $value =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] ||
        error "endpoint-hostname is not a valid hostname (got: '$value')"
}

validate_docker_name() {
    local value=$1
    local label=$2
    [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
        error "$label is not a valid Docker name (got: '$value')"
}

wait_for_toxiproxy() {
    local url=$1
    local timeout=$2
    local elapsed=0
    echo "Waiting for Toxiproxy at $url ..."
    while ((elapsed < timeout)); do
        if curl -sf "$url/version" >/dev/null; then
            echo "Toxiproxy is ready (${elapsed}s)"
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))
    done
    echo "Error: Toxiproxy did not become ready within ${timeout}s" >&2
    return 1
}

main() {
    while [[ $# -gt 0 ]]; do
        case $1 in
        --help | -h)
            show_help
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            show_help
            exit 1
            ;;
        *)
            echo "Unexpected positional argument: $1" >&2
            show_help
            exit 1
            ;;
        esac
    done

    if [[ ${ENABLE_BASH_TRACE_MODE-} == "true" ]]; then
        set -x
    fi

    local container_names=${CONTAINER_NAMES-}
    local aerospike_network=${AEROSPIKE_NETWORK_NAME-}
    local client_network=${CLIENT_NETWORK_NAME:-discovery-client-net}
    local endpoint_hostname=${ENDPOINT_HOSTNAME:-as-endpoint.test}
    local listen_port_base=${LISTEN_PORT_BASE:-30001}
    local upstream_port=${UPSTREAM_PORT:-3000}
    local tls_listen_port_base=${TLS_LISTEN_PORT_BASE-}
    local tls_upstream_port=${TLS_UPSTREAM_PORT:-4333}
    local proxy_container=${PROXY_CONTAINER_NAME:-toxiproxy}
    local toxiproxy_image=${TOXIPROXY_IMAGE:-ghcr.io/shopify/toxiproxy:2.12.0}
    local toxiproxy_control_port=${TOXIPROXY_CONTROL_PORT:-8474}
    local startup_timeout=${STARTUP_TIMEOUT:-30}
    local output_file=${GITHUB_OUTPUT-}

    [[ -n $container_names ]] || error "container-names is required"
    [[ -n $aerospike_network ]] || error "aerospike-network-name is required"

    validate_docker_name "$aerospike_network" "aerospike-network-name"
    validate_docker_name "$client_network" "client-network-name"
    validate_docker_name "$proxy_container" "proxy-container-name"
    validate_hostname "$endpoint_hostname"
    validate_port "$listen_port_base" "listen-port-base"
    validate_port "$upstream_port" "upstream-port"
    validate_port "$toxiproxy_control_port" "toxiproxy-control-port"
    [[ $startup_timeout =~ ^[1-9][0-9]*$ ]] ||
        error "startup-timeout must be a positive integer (got: '$startup_timeout')"

    if [[ -n $tls_listen_port_base ]]; then
        validate_port "$tls_listen_port_base" "tls-listen-port-base"
        validate_port "$tls_upstream_port" "tls-upstream-port"
    fi

    docker network inspect "$aerospike_network" >/dev/null 2>&1 ||
        error "Aerospike Docker network '$aerospike_network' does not exist"

    parse_container_names "$container_names"
    validate_listen_range "$listen_port_base"
    if [[ -n $tls_listen_port_base ]]; then
        validate_listen_range "$tls_listen_port_base"
    fi

    local missing=()
    local name
    for name in "${CONTAINER_NAME_LIST[@]}"; do
        if ! docker inspect "$name" >/dev/null 2>&1; then
            missing+=("$name")
        fi
    done
    if ((${#missing[@]} > 0)); then
        error "Aerospike containers not found: ${missing[*]}"
    fi

    local clear_json tls_json payload
    local endpoint_ports tls_endpoint_ports name_port_map
    clear_json=$(build_proxy_json "$listen_port_base" "$upstream_port")
    endpoint_ports=$(build_listen_ports_csv "$listen_port_base")
    name_port_map=$(build_name_port_csv "$listen_port_base")
    tls_json="[]"
    tls_endpoint_ports=""
    if [[ -n $tls_listen_port_base ]]; then
        tls_json=$(build_proxy_json "$tls_listen_port_base" "$tls_upstream_port" "-tls")
        tls_endpoint_ports=$(build_listen_ports_csv "$tls_listen_port_base")
        name_port_map+=",$(build_name_port_csv "$tls_listen_port_base" "-tls")"
    fi
    payload=$(merge_json_arrays "$clear_json" "$tls_json")

    if ! docker network inspect "$client_network" >/dev/null 2>&1; then
        docker network create "$client_network"
        echo "Created Docker network: $client_network"
    else
        echo "Docker network already exists: $client_network"
    fi

    echo "Pulling Toxiproxy image: $toxiproxy_image"
    docker pull "$toxiproxy_image"

    echo "Starting Toxiproxy: $proxy_container"
    docker run \
        --name "$proxy_container" \
        --detach \
        --network "$aerospike_network" \
        "$toxiproxy_image" \
        -host=0.0.0.0 \
        -port="$toxiproxy_control_port"
    PROXY_CONTAINER_NAME=$proxy_container

    docker network connect --alias "$endpoint_hostname" "$client_network" "$proxy_container"

    local toxiproxy_ip
    toxiproxy_ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$aerospike_network\").IPAddress}}" "$proxy_container")
    [[ -n $toxiproxy_ip ]] || error "could not determine Toxiproxy IP on $aerospike_network"

    local toxiproxy_admin="http://${toxiproxy_ip}:${toxiproxy_control_port}"
    wait_for_toxiproxy "$toxiproxy_admin" "$startup_timeout"

    echo "Configuring proxies: $payload"
    curl -sf -X POST "$toxiproxy_admin/populate" \
        -H "Content-Type: application/json" \
        -d "$payload"

    local toxiproxy_url="http://${proxy_container}:${toxiproxy_control_port}"

    if [[ -n $output_file ]]; then
        {
            echo "client-network-name=$client_network"
            echo "endpoint-hostname=$endpoint_hostname"
            echo "endpoint-port-base=$listen_port_base"
            echo "endpoint-ports=$endpoint_ports"
            echo "tls-endpoint-ports=$tls_endpoint_ports"
            echo "proxy-name-port-map=$name_port_map"
            echo "toxiproxy-url=$toxiproxy_url"
            echo "toxiproxy-container-name=$proxy_container"
            echo "proxy-map-json<<EOF"
            echo "$payload"
            echo "EOF"
        } >>"$output_file"
    fi

    echo "============================================"
    echo "L2 discovery topology"
    echo "============================================"
    echo "Endpoint: ${endpoint_hostname} ports ${endpoint_ports}"
    echo "Toxiproxy control (from client network): $toxiproxy_url"
    echo "Client network: $client_network"
    echo "Aerospike network: $aerospike_network"
    echo "Attach the client with: docker run --network $client_network ..."
    echo "============================================"
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    main "$@"
fi
