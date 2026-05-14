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

    if [[ $server_edition == "enterprise" && (-n $features_path || -n $features_content) ]]; then
        printf '%s\n' "feature-key-file /etc/aerospike/features.conf"
    fi
}

config_declares_feature_key_file() {
    local config_path=$1

    grep -Eq '^[[:space:]]*feature-key-file[[:space:]]+' "$config_path"
}

strip_feature_key_file_directive() {
    local source_config=$1
    local target_config=$2

    sed '/^[[:space:]]*feature-key-file[[:space:]]/d' "$source_config" >"$target_config"
}
