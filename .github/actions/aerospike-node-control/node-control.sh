#!/usr/bin/env bash
# Start or stop node <prefix>-<index> of a setup-aerospike-server cluster and
# wait until every running node reports a stable cluster of the running nodes.
set -euo pipefail

if [[ ${ENABLE_BASH_TRACE_MODE-} == "true" ]]; then
    set -x
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
setup_dir="$script_dir/../setup-aerospike-server"
# shellcheck source=/dev/null
source "$setup_dir/config-helpers.sh"

error() {
    echo "Error: $1" >&2
    exit 1
}

prefix=aerospike
node_index=""
operation=""
network=aerospike-net
service_port=3000
timeout=30
security="false"
enable_sc="false"
tools_image=""

while [[ $# -gt 0 ]]; do
    case $1 in
    --container-name-prefix) prefix=$2 ;;
    --node-index) node_index=$2 ;;
    --operation) operation=$2 ;;
    --network) network=$2 ;;
    --service-port) service_port=$2 ;;
    --timeout) timeout=$2 ;;
    --security) security=$2 ;;
    --enable-sc) enable_sc=$2 ;;
    --tools-image) tools_image=$2 ;;
    *) error "Unknown option: $1" ;;
    esac
    shift 2
done

[[ $node_index =~ ^[1-9][0-9]*$ ]] || error "node-index must be a positive integer (got: '$node_index')"
[[ $operation == "start" || $operation == "stop" ]] || error "operation must be 'start' or 'stop' (got: '$operation')"

name="${prefix}-${node_index}"
running=$(docker inspect --format '{{.State.Running}}' "$name" 2>/dev/null) ||
    error "container $name does not exist"

if [[ $operation == "start" ]]; then
    [[ $running == "false" ]] || error "$name is already running"
    echo "Starting container: $name"
    docker start "$name"
else
    [[ $running == "true" ]] || error "$name is not running"
    echo "Stopping container: $name"
    docker stop "$name"
fi

running_nodes=""
cluster_size=0
while IFS= read -r container; do
    suffix=${container#"$prefix"-}
    if [[ $container == "$prefix"-* && $suffix =~ ^[0-9]+$ ]]; then
        running_nodes+="${running_nodes:+,}$container"
        cluster_size=$((cluster_size + 1))
    fi
done < <(docker ps --format '{{.Names}}')

if ((cluster_size > 0)); then
    bash "$setup_dir/wait-for-aerospike-server.sh" \
        --container-names "$running_nodes" \
        --cluster-size "$cluster_size" \
        --timeout "$timeout" \
        --service-port "$service_port" \
        --security "$security" \
        --enable-sc "$enable_sc" \
        --tools-image "$tools_image" \
        --network "$network"
fi

echo "Running nodes: ${running_nodes:-(none)} (cluster size $cluster_size)"
{
    echo "cluster-size=$cluster_size"
    echo "running-nodes=$running_nodes"
    echo "node-address=$(container_address "$name" "$network")"
} >>"${GITHUB_OUTPUT:-/dev/stdout}"
