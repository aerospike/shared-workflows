#!/usr/bin/env bash
# Create the Docker network for setup-aerospike-server, or reuse an existing
# one. With --subnet, an existing network must already have that subnet.
set -euo pipefail

if [[ ${ENABLE_BASH_TRACE_MODE-} == "true" ]]; then
    set -x
fi

error() {
    echo "Error: $1" >&2
    exit 1
}

network=""
subnet=""

while [[ $# -gt 0 ]]; do
    case $1 in
    --network) network=$2 ;;
    --subnet) subnet=$2 ;;
    *) error "Unknown option: $1" ;;
    esac
    shift 2
done

if ! docker network inspect "$network" >/dev/null 2>&1; then
    if [[ -n $subnet ]]; then
        docker network create --subnet "$subnet" "$network"
    else
        docker network create "$network"
    fi
    echo "Created Docker network: $network"
else
    if [[ -n $subnet ]]; then
        subnets=$(docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' "$network")
        if [[ " $subnets " != *" $subnet "* ]]; then
            error "Docker network $network already exists with subnet(s) '${subnets% }', not network-subnet $subnet"
        fi
    fi
    echo "Docker network already exists: $network"
fi
echo "network-name=$network" >>"${GITHUB_OUTPUT:-/dev/stdout}"
