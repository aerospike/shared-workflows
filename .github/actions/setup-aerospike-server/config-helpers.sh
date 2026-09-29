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
