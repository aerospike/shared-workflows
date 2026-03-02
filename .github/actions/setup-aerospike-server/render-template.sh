#!/usr/bin/env bash
# render-template.sh — Render an Aerospike config template by replacing placeholders.
#
# Usage: render-template.sh <template-file>
#
# Replaces __PLACEHOLDER__ markers in the template with values from
# environment variables named TPL_PLACEHOLDER. For example, TPL_SECURITY
# replaces __SECURITY__. Outputs the rendered config to stdout.
#
# Example:
#   TPL_SECURITY="security { ... }" TPL_NAMESPACE="namespace test { ... }" \
#     ./render-template.sh templates/default.conf

set -euo pipefail

template="$1"

if [[ ! -f $template ]]; then
    echo "Error: template file not found: $template" >&2
    exit 1
fi

rendered=$(mktemp)
cp "$template" "$rendered"

# Find all TPL_* environment variables and replace corresponding placeholders
while IFS='=' read -r name _; do
    if [[ $name == TPL_* ]]; then
        placeholder="__${name#TPL_}__"
        value="${!name}"

        content_file=$(mktemp)
        printf '%s\n' "$value" >"$content_file"

        next=$(mktemp)
        sed "/${placeholder}/{
      r $content_file
      d
    }" "$rendered" >"$next"
        mv "$next" "$rendered"

        rm -f "$content_file"
    fi
done < <(env)

cat "$rendered"
rm -f "$rendered"
