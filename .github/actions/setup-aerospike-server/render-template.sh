#!/usr/bin/env bash
# render-template.sh — Render an Aerospike config template using bash variable expansion.
#
# Usage: render-template.sh <template-file> [<output-file>]
#
# Evaluates ${VARIABLE} references in the template using the current environment.
# Lines containing variable references that expand to empty are omitted.
# If no output file is given, writes to stdout.
#
# Example:
#   export SECURITY="security { ... }" NAMESPACE="namespace test { ... }"
#   ./render-template.sh templates/default.conf /tmp/aerospike.conf

set -euo pipefail

template="$1"
target="${2:-/dev/stdout}"

if [[ ! -f $template ]]; then
    echo "Error: template file not found: $template" >&2
    exit 1
fi

: >"$target"

while IFS= read -r line; do
    if grep -qE '[$][(]|[$][{]' <<<"${line}"; then
        update=$(eval echo "\"${line}\"") || exit 1
        grep -qE '[^[:space:]]' <<<"${update}" && echo "${update}" >>"$target"
    else
        echo "${line}" >>"$target"
    fi
done <"$template"
