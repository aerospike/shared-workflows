#!/usr/bin/env bash
set -euo pipefail

export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
trap 'handle_error ${LINENO}' ERR
# shellcheck disable=SC2317
handle_error() {
    local exit_code=$?
    local line_number=$1
    echo "Error: Command failed with exit code $exit_code at line $line_number" >&2
    if [[ -n ${STARTED_CONTAINER-} ]]; then
        echo "CoreDNS logs:" >&2
        docker logs "$STARTED_CONTAINER" >&2 || true
    fi
    exit "$exit_code"
}

DEFAULT_COREDNS_IMAGE="docker.io/coredns/coredns@sha256:9caabbf6238b189a65d0d6e6ac138de60d6a1c419e5a341fbbb7c78382559c6e" # 1.11.3
PROBE_IMAGE="docker.io/library/busybox@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e" # 1.37.0
COREDNS_DIR=/etc/coredns
STARTED_CONTAINER=""

error() {
    local reason="${1-}"
    if [[ -n $reason ]]; then
        echo "Error: $reason" >&2
    else
        echo "Error" >&2
    fi
    exit 1
}

show_help() {
    echo "Usage: $0 [OPTIONS]" >&2
    echo "" >&2
    echo "Start CoreDNS on an existing Docker network, serving one zone from zone file" >&2
    echo "text, and wait until it answers the zone's SOA query." >&2
    echo "" >&2
    echo "Inputs are read from environment variables (set by action.yaml)." >&2
    echo "  --help, -h    Show this help message" >&2
}

validate_docker_name() {
    local value=$1
    local label=$2
    [[ $value =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
        error "$label is not a valid Docker name (got: '$value')"
}

validate_zone_name() {
    local value=${1%.}
    local label='[A-Za-z0-9_]([A-Za-z0-9_-]{0,61}[A-Za-z0-9_])?'
    [[ ${#value} -le 253 && $value =~ ^($label\.)*$label$ ]] ||
        error "zone-name is not a valid domain name (got: '$1')"
}

zone_file_path() {
    echo "$COREDNS_DIR/db.$1"
}

render_corefile() {
    local zone=$1
    cat <<EOF
$zone:53 {
    file $(zone_file_path "$zone") {
        reload 1s
    }
    errors
    log
}
EOF
}

container_running() {
    [[ $(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null) == "true" ]]
}

wait_for_dns() {
    local container=$1
    local network=$2
    local address=$3
    local zone=$4
    local timeout=$5
    local start=$SECONDS
    echo "Waiting for $address to answer SOA $zone ..."
    while ((SECONDS - start < timeout)); do
        if ! container_running "$container"; then
            echo "Error: $container is not running" >&2
            return 1
        fi
        if docker run --rm --network "$network" "$PROBE_IMAGE" \
            nslookup -type=soa "$zone" "$address" >/dev/null 2>&1; then
            echo "DNS server is ready ($((SECONDS - start))s)"
            return 0
        fi
        sleep 1
    done
    echo "Error: DNS server did not answer SOA $zone within ${timeout}s" >&2
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

    local network=${NETWORK_NAME-}
    local zone_content=${ZONE_CONTENT-}
    local zone_name=${ZONE_NAME-}
    local container=${CONTAINER_NAME:-coredns}
    local image=${COREDNS_IMAGE:-$DEFAULT_COREDNS_IMAGE}
    local startup_timeout=${STARTUP_TIMEOUT:-30}
    local output_file=${GITHUB_OUTPUT-}

    [[ -n $network ]] || error "network-name is required"
    [[ -n ${zone_content//[[:space:]]/} ]] || error "zone-content is required"
    [[ -n $zone_name ]] || error "zone-name is required"

    validate_docker_name "$network" "network-name"
    validate_docker_name "$container" "container-name"
    validate_zone_name "$zone_name"
    local zone=${zone_name%.}
    grep -qiE '(^|[[:space:]])SOA([[:space:]]|$)' <<<"$zone_content" ||
        error "zone-content has no SOA record"
    [[ $startup_timeout =~ ^[1-9][0-9]*$ ]] ||
        error "startup-timeout must be a positive integer (got: '$startup_timeout')"

    docker network inspect "$network" >/dev/null 2>&1 ||
        error "Docker network '$network' does not exist"
    if docker inspect "$container" >/dev/null 2>&1; then
        error "container '$container' already exists"
    fi

    echo "Pulling CoreDNS image: $image"
    docker pull "$image"
    echo "Pulling probe image: $PROBE_IMAGE"
    docker pull "$PROBE_IMAGE"

    local work_dir
    work_dir=$(mktemp -d)
    chmod 755 "$work_dir"
    render_corefile "$zone" >"$work_dir/Corefile"
    printf '%s\n' "$zone_content" >"$work_dir/db.$zone"
    chmod 644 "$work_dir/Corefile" "$work_dir/db.$zone"
    echo "Corefile:"
    cat "$work_dir/Corefile"

    echo "Starting CoreDNS: $container"
    docker create \
        --name "$container" \
        --network "$network" \
        "$image" \
        -conf "$COREDNS_DIR/Corefile" >/dev/null
    STARTED_CONTAINER=$container
    docker cp "$work_dir/." "$container:$COREDNS_DIR/"
    rm -rf "$work_dir"
    docker start "$container" >/dev/null

    local address
    address=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" "$container")
    [[ -n $address ]] || error "could not determine $container IP on $network"

    if ! wait_for_dns "$container" "$network" "$address" "$zone" "$startup_timeout"; then
        echo "CoreDNS logs:" >&2
        docker logs "$container" >&2 || true
        error "DNS server for zone '$zone' did not become ready"
    fi

    if [[ -n $output_file ]]; then
        {
            echo "server-address=$address"
            echo "container-name=$container"
        } >>"$output_file"
    fi

    echo "============================================"
    echo "DNS server"
    echo "============================================"
    echo "Zone: $zone"
    echo "Server: $address:53 (UDP and TCP) on $network"
    echo "Zone file: $container:$(zone_file_path "$zone")"
    echo "Change records: raise the SOA serial and docker cp the new zone file to the path above"
    echo "============================================"
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    main "$@"
fi
