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

strip_feature_key_file_directive() {
    local source_config=$1
    local target_config=$2

    sed '/^[[:space:]]*feature-key-file[[:space:]]/d' "$source_config" >"$target_config"
}

# Point a custom aerospike.conf at the features file this action mounted.
# An existing feature-key-file line is rewritten in place. Otherwise the
# directive is inserted into the first service context, or a service context
# is appended when the config has none.
inject_feature_key_file_directive() {
    local source_config=$1
    local target_config=$2
    local feature_path_in_container=$3

    # Rewrite first. The service context is seen before a directive that lives
    # inside it, so a single pass would both insert and keep the old line.
    if config_declares_feature_key_file "$source_config"; then
        awk -v path="$feature_path_in_container" '
            /^[[:space:]]*feature-key-file[[:space:]]+/ {
                match($0, /^[[:space:]]*/)
                print substr($0, 1, RLENGTH) "feature-key-file " path
                next
            }
            { print }
        ' "$source_config" >"$target_config"
        return
    fi

    awk -v path="$feature_path_in_container" '
        BEGIN { inserted = 0 }
        /^[[:space:]]*service[[:space:]]*\{/ && inserted == 0 {
            print
            print "    feature-key-file " path
            inserted = 1
            next
        }
        { print }
        END {
            if (inserted == 0) {
                print "service {"
                print "    feature-key-file " path
                print "}"
            }
        }
    ' "$source_config" >"$target_config"
}
