#!/usr/bin/env bash
# parse-build-env.sh
#
# Parse the BUILD_ENV input format used by reusable_execute-build.yaml.
# Format: semicolon-delimited KEY=VALUE pairs. Use '\;' for a literal
# semicolon inside a value, '\\' for a literal backslash.
#
# Reads BUILD_ENV from the environment. Emits one 'KEY=VALUE' line per pair
# to stdout. The caller decides what to do with the output (typically:
# apply via `export` for the current shell AND append to $GITHUB_ENV for
# subsequent steps). Exits non-zero on a malformed pair or invalid key name.

set -euo pipefail

error() {
    echo "Error: $*" >&2
    exit 1
}

emit() {
    echo "$1=$2"
}

main() {
    local input="${BUILD_ENV-}"
    if [[ -z $input ]]; then
        return 0
    fi

    local current=""
    local escape="false"
    local -a pairs=()
    local i char
    for ((i = 0; i < ${#input}; i++)); do
        char="${input:i:1}"
        if [[ $escape == "true" ]]; then
            current+="$char"
            escape="false"
            continue
        fi
        # shellcheck disable=SC1003 # '\' is a literal backslash; trunk shfmt prefers single quotes here
        if [[ $char == '\' ]]; then
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

    local pair key value
    for pair in "${pairs[@]}"; do
        [[ -z $pair ]] && continue
        if [[ $pair != *=* ]]; then
            error "build-env entries must be KEY=VALUE (got: $pair)"
        fi
        key="${pair%%=*}"
        value="${pair#*=}"
        if [[ -z $key || ! $key =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
            error "invalid env var name '$key' in build-env"
        fi
        emit "$key" "$value"
    done
}

main "$@"
