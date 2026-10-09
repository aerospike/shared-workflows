#!/usr/bin/env bash
# Build Toxiproxy populate payloads from setup-aerospike-server container-names.

error() {
    local reason="${1-}"
    if [[ -n $reason ]]; then
        echo "Error: $reason" >&2
    else
        echo "Error" >&2
    fi
    exit 1
}

# CONTAINER_NAME_LIST is filled by parse_container_names.
CONTAINER_NAME_LIST=()

parse_container_names() {
    local csv=${1-}
    local name trimmed
    local -a names
    local -A seen
    CONTAINER_NAME_LIST=()

    [[ -n $csv ]] || error "container-names is required"

    IFS=',' read -ra names <<<"$csv"
    for name in "${names[@]}"; do
        trimmed="${name#"${name%%[![:space:]]*}"}"
        trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
        [[ -n $trimmed ]] || error "container-names contains an empty name"
        [[ $trimmed =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] ||
            error "invalid container name '$trimmed' (must match Docker name rules)"
        [[ -v seen[$trimmed] ]] && error "duplicate container name '$trimmed'"
        seen[$trimmed]=1
        CONTAINER_NAME_LIST+=("$trimmed")
    done
}

validate_port() {
    local value=$1
    local label=$2
    [[ $value =~ ^[1-9][0-9]*$ ]] || error "$label must be a positive integer (got: '$value')"
    ((value <= 65535)) || error "$label must be <= 65535 (got: $value)"
}

validate_listen_range() {
    local listen_base=$1
    local count=${#CONTAINER_NAME_LIST[@]}
    local last=$((listen_base + count - 1))
    ((last <= 65535)) || error "listen ports would exceed 65535 (base $listen_base, $count nodes)"
}

# Prints a JSON array suitable for POST /populate.
# name_suffix is appended to each proxy name (e.g. -tls).
build_proxy_json() {
    local listen_base=$1
    local upstream_port=$2
    local name_suffix=${3-}
    local i=0
    local json="["
    local name listen_port proxy_name

    for name in "${CONTAINER_NAME_LIST[@]}"; do
        listen_port=$((listen_base + i))
        proxy_name="${name}${name_suffix}"
        if ((i > 0)); then
            json+=","
        fi
        json+=$(printf '{"name":"%s","listen":"0.0.0.0:%s","upstream":"%s:%s","enabled":true}' \
            "$proxy_name" "$listen_port" "$name" "$upstream_port")
        i=$((i + 1))
    done
    json+="]"
    printf '%s\n' "$json"
}

build_listen_ports_csv() {
    local listen_base=$1
    local i=0
    local csv=""
    local listen_port

    for _name in "${CONTAINER_NAME_LIST[@]}"; do
        listen_port=$((listen_base + i))
        if ((i > 0)); then
            csv+=","
        fi
        csv+="$listen_port"
        i=$((i + 1))
    done
    printf '%s\n' "$csv"
}

build_name_port_csv() {
    local listen_base=$1
    local name_suffix=${2-}
    local i=0
    local csv=""
    local name listen_port

    for name in "${CONTAINER_NAME_LIST[@]}"; do
        listen_port=$((listen_base + i))
        if ((i > 0)); then
            csv+=","
        fi
        csv+="${name}${name_suffix}:${listen_port}"
        i=$((i + 1))
    done
    printf '%s\n' "$csv"
}

merge_json_arrays() {
    local a=$1
    local b=$2
    if [[ $a == "[]" ]]; then
        printf '%s\n' "$b"
    elif [[ $b == "[]" ]]; then
        printf '%s\n' "$a"
    else
        printf '%s\n' "${a%]},${b#\[}"
    fi
}
