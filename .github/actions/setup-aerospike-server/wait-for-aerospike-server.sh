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
TIMEOUT=30
SERVICE_PORT=3000
SECURITY="false"
ENABLE_SC="false"
TOOLS_IMAGE=""
NETWORK=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
    --container-names)
        CONTAINER_NAMES="$2"
        shift 2
        ;;
    --timeout)
        TIMEOUT="$2"
        shift 2
        ;;
    --service-port)
        SERVICE_PORT="$2"
        shift 2
        ;;
    --security)
        SECURITY="$2"
        shift 2
        ;;
    --enable-sc)
        ENABLE_SC="$2"
        shift 2
        ;;
    --tools-image)
        TOOLS_IMAGE="$2"
        shift 2
        ;;
    --network)
        NETWORK="$2"
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

echo "Waiting for cluster stability..."

ignore_migrations="$ENABLE_SC"

# SC mode: use tools container with asinfo to check cluster-stable
# SC partitions won't complete migrations until roster is set up,
# so we use ignore-migrations=true
auth_flags=""
if [[ $SECURITY == "true" ]]; then
    auth_flags="-U admin -P admin"
fi

echo "  Tools image: $TOOLS_IMAGE"
echo "  Network: $NETWORK"
echo "  Auth flags: ${auth_flags:-(none)}"

docker pull "$TOOLS_IMAGE"

# shellcheck disable=SC2086
for container in "${containers[@]}"; do
    echo "  Waiting for $container to stabilize..."
    elapsed=0
    stable="false"
    while ((elapsed < TIMEOUT)); do
        echo "Elapsed:" "$elapsed"
        rc=0
        result=$(docker run --rm --network "$NETWORK" "$TOOLS_IMAGE" \
            asinfo -h "$container" -p "$SERVICE_PORT" $auth_flags \
            -v "cluster-stable:ignore-migrations=${ignore_migrations}" 2>&1) || rc=$?
        echo "    [${elapsed}s] Exit code: $rc, Output: $result"
        # A non-ERROR response containing a cluster key means stable
        if [[ $rc -eq 0 && -n $result && $result != *"ERROR"* ]]; then
            echo "  $container is stable (${elapsed}s): $result"
            stable="true"
            break
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [[ $stable != "true" ]]; then
        echo "Error: $container did not stabilize within ${TIMEOUT}s" >&2
        echo "Container logs:" >&2
        docker logs "$container" >&2
        exit 1
    fi
done

echo "All nodes are stable."

echo "Aerospike Server is ready."
