#!/usr/bin/env bash

resolve_server_edition() {
    local requested=$1
    local server_repo=$2
    local repo_name=${server_repo##*/}

    case "$requested" in
    enterprise | community)
        printf '%s\n' "$requested"
        ;;
    auto)
        if [[ $repo_name == "aerospike-server-enterprise" ]]; then
            printf '%s\n' "enterprise"
        elif [[ $repo_name == "aerospike-server" ]]; then
            printf '%s\n' "community"
        else
            printf 'Error: server-edition auto cannot infer edition from server-container-repo %q; set server-edition explicitly\n' "$server_repo" >&2
            return 1
        fi
        ;;
    *)
        return 1
        ;;
    esac
}

should_use_features_file() {
    local server_edition=$1
    local features_path=$2

    [[ $server_edition == "enterprise" && -n $features_path ]]
}

build_feature_key_file_directive() {
    local server_edition=$1
    local features_path=$2
    local features_content=$3
    local feature_path_in_container=$4

    if [[ $server_edition == "enterprise" && (-n $features_path || -n $features_content) ]]; then
        printf '%s\n' "feature-key-file $feature_path_in_container"
    fi
}

config_declares_feature_key_file() {
    local config_path=$1

    grep -Eq '^[[:space:]]*feature-key-file[[:space:]]+' "$config_path"
}

# TLS_CONFIG and TLS_SERVICE are expanded by render-template.sh.
# Empty values omit those lines, so the same templates cover TLS and non-TLS.
export_tls_template_vars() {
    local tpl_dir=$1
    local enable_tls=$2

    TLS_CONFIG=""
    TLS_SERVICE=""
    if [[ $enable_tls == "true" ]]; then
        TLS_CONFIG=$(cat "$tpl_dir/tls-network.conf")
        TLS_SERVICE=$(cat "$tpl_dir/tls-service.conf")
    fi
    export TLS_CONFIG
    export TLS_SERVICE
}

strip_feature_key_file_directive() {
    local source_config=$1
    local target_config=$2

    sed '/^[[:space:]]*feature-key-file[[:space:]]/d' "$source_config" >"$target_config"
}

# Replace {{NODE_INDEX}} and {{NODE_NAME}} by plain string substitution, so
# nothing else in the config is expanded or executed.
render_node_config() {
    local source_config=$1
    local target_config=$2
    local node_index=$3
    local node_name=$4
    local index_token='{{NODE_INDEX}}'
    local name_token='{{NODE_NAME}}'
    local content

    content=$(
        cat "$source_config"
        printf x
    )
    content=${content%x}
    content=${content//"$index_token"/$node_index}
    content=${content//"$name_token"/$node_name}
    printf '%s' "$content" >"$target_config"
}

# Print one name:ip per line from comma-separated extra-hosts entries.
parse_extra_hosts() {
    local extra_hosts=$1
    local entry name address
    local -a entries=()

    IFS=',' read -rd '' -a entries <<<"$extra_hosts" || true
    for entry in "${entries[@]}"; do
        entry="${entry#"${entry%%[![:space:]]*}"}"
        entry="${entry%"${entry##*[![:space:]]}"}"
        [[ -z $entry ]] && continue
        name=${entry%%:*}
        address=${entry#*:}
        if [[ $entry != *:* ]] ||
            [[ ! $name =~ ^[A-Za-z0-9]([A-Za-z0-9_.-]{0,251}[A-Za-z0-9])?$ ]] ||
            [[ ! $address =~ ^(([0-9]{1,3}[.]){3}[0-9]{1,3}|[0-9A-Fa-f]*:[0-9A-Fa-f:.]*|host-gateway)$ ]]; then
            printf 'Error: extra-hosts entries must be name:ip (got: %q)\n' "$entry" >&2
            return 1
        fi
        printf '%s\n' "$name:$address"
    done
}

# Set ENV_FLAGS to -e flags from semicolon-delimited env-vars, where \; is a
# literal semicolon and \\ a literal backslash.
parse_env_vars() {
    local env_vars=$1
    local current="" escape="false" char pair key i
    local -a pairs=()

    ENV_FLAGS=()
    [[ -n $env_vars ]] || return 0
    for ((i = 0; i < ${#env_vars}; i++)); do
        char="${env_vars:i:1}"
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
            printf 'Error: env-vars entries must be KEY=VALUE (got: %s)\n' "$pair" >&2
            return 1
        fi
        key="${pair%%=*}"
        if [[ -z $key || ! $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            printf "Error: invalid env var name '%s' in env-vars\n" "$key" >&2
            return 1
        fi
        ENV_FLAGS+=("-e" "$pair")
    done
}
