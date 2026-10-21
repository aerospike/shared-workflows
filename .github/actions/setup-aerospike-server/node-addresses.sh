#!/usr/bin/env bash
# Write node-addresses: each container's IP on the network, in the order of
# --container-names. With --subnet, the fixed IPs from subnet_node_addresses.
set -euo pipefail

if [[ ${ENABLE_BASH_TRACE_MODE-} == "true" ]]; then
    set -x
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$script_dir/config-helpers.sh"

error() {
    echo "Error: $1" >&2
    exit 1
}

container_names=""
network=""
subnet=""

while [[ $# -gt 0 ]]; do
    case $1 in
    --container-names) container_names=$2 ;;
    --network) network=$2 ;;
    --subnet) subnet=$2 ;;
    *) error "Unknown option: $1" ;;
    esac
    shift 2
done

IFS=',' read -ra containers <<<"$container_names"

node_addresses=""
if [[ -n $subnet ]]; then
    subnet_addresses=$(subnet_node_addresses "$subnet" "${#containers[@]}") || exit 1
    IFS=$'\n' read -rd '' -a fixed_addresses <<<"$subnet_addresses" || true
fi
for ((i = 0; i < ${#containers[@]}; i++)); do
    if [[ -n $subnet ]]; then
        address=${fixed_addresses[i]}
    else
        address=$(container_address "${containers[i]}" "$network")
    fi
    if ((i > 0)); then
        node_addresses+=","
    fi
    node_addresses+="$address"
done

echo "node-addresses=$node_addresses" >>"${GITHUB_OUTPUT:-/dev/stdout}"
