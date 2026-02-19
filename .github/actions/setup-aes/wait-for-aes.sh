#!/usr/bin/env bash
set -euo pipefail

export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
trap 'handle_error ${LINENO}' ERR

# shellcheck disable=SC2317
handle_error() {
    local exit_code=$?
    local line_number=$1
    echo "Error: Command failed with exit code $exit_code at line $line_number" >&2
    exit 1
}

# Default values
CONTAINER_NAMES=""
NUM_NODES=1
TIMEOUT=30

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
    --container-names)
        CONTAINER_NAMES="$2"
        shift 2
        ;;
    --num-nodes)
        NUM_NODES="$2"
        shift 2
        ;;
    --timeout)
        TIMEOUT="$2"
        shift 2
        ;;
    *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
    esac
done

if [[ -z $CONTAINER_NAMES ]]; then
    echo "Error: --container-names is required" >&2
    exit 1
fi

# Convert CSV to array
IFS=',' read -ra containers <<<"$CONTAINER_NAMES"

# Phase 1: Wait for each node to report status ok
echo "Phase 1: Waiting for individual node readiness..."
for container in "${containers[@]}"; do
    echo "  Waiting for $container..."
    elapsed=0
    while ((elapsed < TIMEOUT)); do
        status=$(docker exec "$container" asinfo -v status 2>/dev/null || true)
        if [[ $status == "ok" ]]; then
            echo "  $container is ready (${elapsed}s)"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [[ $status != "ok" ]]; then
        echo "Error: $container did not become ready within ${TIMEOUT}s" >&2
        echo "Last 20 lines of container logs:" >&2
        docker logs --tail 20 "$container" >&2
        exit 1
    fi
done
echo "All nodes are ready."

# Phase 2: Wait for cluster formation (only for multi-node)
if ((NUM_NODES > 1)); then
    echo "Phase 2: Waiting for cluster formation (expected size: $NUM_NODES)..."
    first_container="${containers[0]}"
    elapsed=0
    cluster_size=0
    while ((elapsed < TIMEOUT)); do
        cluster_size=$(docker exec "$first_container" asinfo -v cluster-size 2>/dev/null || echo "0")
        if [[ $cluster_size == "$NUM_NODES" ]]; then
            echo "Cluster formed: $cluster_size nodes (${elapsed}s)"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [[ $cluster_size != "$NUM_NODES" ]]; then
        echo "Error: Cluster did not form within ${TIMEOUT}s (expected $NUM_NODES nodes)" >&2
        echo "Per-node cluster-size for debugging:" >&2
        for container in "${containers[@]}"; do
            size=$(docker exec "$container" asinfo -v cluster-size 2>/dev/null || echo "N/A")
            echo "  $container: cluster-size=$size" >&2
        done
        exit 1
    fi
fi

# Phase 3: Wait for cluster stability on every node
# cluster-stable returns a cluster key when stable, or ERROR when not.
# ignore-migrations=true avoids false negatives during partition rebalancing.
echo "Phase 3: Waiting for cluster stability..."
for container in "${containers[@]}"; do
    echo "  Waiting for $container to stabilize..."
    elapsed=0
    stable="false"
    while ((elapsed < TIMEOUT)); do
        result=$(docker exec "$container" asinfo -v "cluster-stable:ignore-migrations=true" 2>&1 || true)
        if [[ $result != ERROR* ]]; then
            echo "  $container is stable: cluster key $result (${elapsed}s)"
            stable="true"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [[ $stable != "true" ]]; then
        echo "Error: $container did not stabilize within ${TIMEOUT}s" >&2
        echo "Last response: $result" >&2
        echo "Last 20 lines of container logs:" >&2
        docker logs --tail 20 "$container" >&2
        exit 1
    fi
done
echo "All nodes are stable."

echo "Aerospike Enterprise Server is ready."
