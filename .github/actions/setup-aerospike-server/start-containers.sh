#!/usr/bin/env bash
# Start the Aerospike Server containers for setup-aerospike-server.
#
# Each node gets its own config file, rendered from the generated template or
# the caller's config with {{NODE_INDEX}} and {{NODE_NAME}} replaced, and
# copied into the config volume as <container-name>.conf.
#
# ENV_VARS (semicolon-delimited KEY=VALUE pairs) and EXTRA_HOSTS
# (comma-separated name:ip entries) are read from the environment.
set -euo pipefail

if [[ ${ENABLE_BASH_TRACE_MODE-} == "true" ]]; then
    set -x
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tpl_dir="$script_dir/templates"
render_tpl="$script_dir/render-template.sh"
# shellcheck source=/dev/null
source "$script_dir/config-helpers.sh"

error() {
    echo "Error: $1" >&2
    exit 1
}

num_nodes=1
base_port=3000
prefix=aerospike
service_port=3000
image=""
network=""
features_path=""
config_path=""
publish_ports="true"
enable_tls="false"
tls_base_port=4333
effective_security="false"
enable_sc="false"
server_edition=""
conf_volume_name=""
conf_volume_dest_dir=""
tls_volume_name=""
tls_volume_dest_dir=""
loader_container=""

while [[ $# -gt 0 ]]; do
    case $1 in
    --num-nodes) num_nodes=$2 ;;
    --base-port) base_port=$2 ;;
    --container-name-prefix) prefix=$2 ;;
    --service-port) service_port=$2 ;;
    --image) image=$2 ;;
    --network) network=$2 ;;
    --features-path) features_path=$2 ;;
    --config-path) config_path=$2 ;;
    --publish-ports) publish_ports=$2 ;;
    --enable-tls) enable_tls=$2 ;;
    --tls-base-port) tls_base_port=$2 ;;
    --security) effective_security=$2 ;;
    --enable-sc) enable_sc=$2 ;;
    --server-edition) server_edition=$2 ;;
    --conf-volume-name) conf_volume_name=$2 ;;
    --conf-volume-dest-dir) conf_volume_dest_dir=$2 ;;
    --tls-volume-name) tls_volume_name=$2 ;;
    --tls-volume-dest-dir) tls_volume_dest_dir=$2 ;;
    --loader-container) loader_container=$2 ;;
    *) error "Unknown option: $1" ;;
    esac
    shift 2
done

container_names=""
service_ports=""
tls_service_ports=""

# Parse env-vars using escape-aware semicolon delimiter
env_flags=()
if [[ -n ${ENV_VARS-} ]]; then
    current=""
    escape="false"
    pairs=()
    for ((i = 0; i < ${#ENV_VARS}; i++)); do
        char="${ENV_VARS:i:1}"
        if [[ $escape == "true" ]]; then
            current+="$char"
            escape="false"
            continue
        fi
        if [[ $char == $'\\' ]]; then
            escape="true"
            continue
        fi
        if [[ $char == ";" ]]; then
            pairs+=("$current")
            current=""
            continue
        fi
        current+="$char"
    done
    pairs+=("$current")

    for pair in "${pairs[@]}"; do
        [[ -z $pair ]] && continue
        if [[ $pair != *=* ]]; then
            error "env-vars entries must be KEY=VALUE (got: $pair)"
        fi
        key="${pair%%=*}"
        value="${pair#*=}"
        if [[ -z $key || ! $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            error "invalid env var name '$key' in env-vars"
        fi
        env_flags+=("-e" "$key=$value")
    done
fi

host_flags=()
if [[ -n ${EXTRA_HOSTS-} ]]; then
    extra_hosts=$(parse_extra_hosts "$EXTRA_HOSTS") || exit 1
    while IFS= read -r extra_host; do
        host_flags+=("--add-host" "$extra_host")
    done <<<"$extra_hosts"
fi

# For multi-node clusters, generate a config with mesh seed addresses
# The entrypoint overwrites mounted configs, so we bypass it and run asd directly
if ((num_nodes > 1)); then
    mesh_seeds=""
    for ((j = 1; j <= num_nodes; j++)); do
        mesh_seeds+="        mesh-seed-address-port ${prefix}-${j} 3002"$'\n'
    done

    if [[ -z $config_path ]]; then
        features_conf_filename=$(basename "$features_path")
        export FEATURE_KEY_FILE
        FEATURE_KEY_FILE=$(build_feature_key_file_directive "$server_edition" "$features_path" "" "$conf_volume_dest_dir/$features_conf_filename")

        # Build security stanza from template
        export SECURITY=""
        if [[ $effective_security == "true" ]]; then
            SECURITY=$(cat "$tpl_dir/security.conf")
        fi

        # Build namespace block from template
        export NAMESPACE
        if [[ $enable_sc == "true" ]]; then
            export REPLICATION_FACTOR=$((num_nodes < 2 ? num_nodes : 2))
            NAMESPACE=$("$render_tpl" "$tpl_dir/namespace-sc.conf")
        else
            export REPLICATION_FACTOR=2
            NAMESPACE=$("$render_tpl" "$tpl_dir/namespace-memory.conf")
        fi

        export MESH_SEEDS="$mesh_seeds"
        export_tls_template_vars "$tpl_dir" "$enable_tls"

        # No config-file or config-content. Render multi-node.conf, with
        # the TLS listener included when enable-tls is set.
        config_path="$(mktemp)"
        "$render_tpl" "$tpl_dir/multi-node.conf" "$config_path"
    else
        # Inject mesh seeds into the user-provided config
        cluster_config="$(mktemp)"
        MESH_SEEDS="$mesh_seeds" awk '/mode mesh/{print; printf "%s", ENVIRON["MESH_SEEDS"]; next}1' "$config_path" >"$cluster_config"
        config_path="$cluster_config"
    fi
fi

node_config_dir=""
if [[ -n $config_path ]]; then
    node_config_dir="$(mktemp -d)"
fi

for ((i = 1; i <= num_nodes; i++)); do
    name="${prefix}-${i}"
    host_port=$((base_port + i - 1))

    tls_host_port=$((tls_base_port + i - 1))

    run_args=(
        "--name" "$name"
        "--detach"
        "--network" "$network"
    )

    if [[ $publish_ports == "true" ]]; then
        run_args+=("-p" "${host_port}:${service_port}")
    fi

    # TLS port mapping and cert mounting
    if [[ $enable_tls == "true" ]]; then
        if [[ $publish_ports == "true" ]]; then
            run_args+=("-p" "${tls_host_port}:4333")
        fi
        run_args+=("-v" "$tls_volume_name:$tls_volume_dest_dir")
    fi

    # Decide whether to bypass the entrypoint. The Aerospike Docker entrypoint
    # regenerates aerospike.conf, overwriting any mounted config. Bypass it
    # whenever we need a custom config that must not be overwritten.
    bypass_entrypoint="false"
    if ((num_nodes > 1)); then
        bypass_entrypoint="true"
    elif [[ $enable_sc == "true" ]]; then
        bypass_entrypoint="true"
    elif [[ $enable_tls == "true" ]]; then
        bypass_entrypoint="true"
    elif [[ $effective_security == "true" ]]; then
        bypass_entrypoint="true"
    elif [[ -n $config_path ]]; then
        bypass_entrypoint="true"
    fi

    # User-supplied env vars and host entries
    run_args+=("${env_flags[@]}")
    run_args+=("${host_flags[@]}")

    if [[ -n $config_path || -n $features_path ]]; then
        run_args+=("-v" "$conf_volume_name:$conf_volume_dest_dir")
    fi

    run_args+=("--ulimit" "nofile=15000")

    # Bypass entrypoint to prevent config overwrite
    if [[ $bypass_entrypoint == "true" ]]; then
        run_args+=("--entrypoint" "asd")
    fi

    run_args+=("$image")

    # Pass --foreground since we bypassed the entrypoint
    if [[ $bypass_entrypoint == "true" ]]; then
        run_args+=("--foreground")
    fi

    if [[ -n $config_path ]]; then
        node_config="$node_config_dir/$name.conf"
        render_node_config "$config_path" "$node_config" "$i" "$name"
        docker cp "$node_config" "$loader_container:$conf_volume_dest_dir"
        run_args+=("--config-file" "$conf_volume_dest_dir/$name.conf")
    fi

    if [[ $publish_ports == "true" ]]; then
        echo "Starting container: $name (host port: $host_port)"
    else
        echo "Starting container: $name (host ports unpublished)"
    fi

    # Prevent UNIX to windows path conversions here to prevent the aerospike.conf path from being wrongly converted
    MSYS_NO_PATHCONV=1 docker run "${run_args[@]}"

    # Build CSV outputs
    if [[ -n $container_names ]]; then
        container_names+=","
        service_ports+=","
    fi
    container_names+="$name"
    service_ports+="$host_port"
    if [[ $enable_tls == "true" ]]; then
        if [[ -n $tls_service_ports ]]; then
            tls_service_ports+=","
        fi
        tls_service_ports+="$tls_host_port"
    fi
done

{
    echo "container-names=$container_names"
    echo "service-ports=$service_ports"
    echo "tls-service-ports=$tls_service_ports"
} >>"${GITHUB_OUTPUT:-/dev/stdout}"
