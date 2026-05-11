#!/usr/bin/env bash

resolve_server_edition() {
    local requested=$1
    local server_repo=$2

    case "$requested" in
    enterprise | community)
        printf '%s\n' "$requested"
        ;;
    auto)
        if [[ $server_repo == *enterprise* ]]; then
            printf '%s\n' "enterprise"
        else
            printf '%s\n' "community"
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

    if [[ $server_edition == "enterprise" && ( -n $features_path || -n $features_content ) ]]; then
        printf '%s\n' "feature-key-file /etc/aerospike/features.conf"
    fi
}
