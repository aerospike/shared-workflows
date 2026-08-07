#!/usr/bin/env bash
# Validate permission scoping on reusable_*.yaml workflows.
#
# Policy:
# - Workflow-level permissions may only grant contents: read and id-token: write.
# - Elevated permissions (actions, packages, attestations, ...) must be job-scoped.
# - Job scoping alone is not enough: a nested job cannot request more than its
#   caller holds, so an elevated permission only works when every caller grants it.
# - reusable_*.yaml files with no workflow-level permissions block are allowed
#   (e.g. reusable_docker-build-deploy.yaml inherits caller grants).

set -euo pipefail

WORKFLOWS_DIR="${1:-.github/workflows}"
ALLOWED_WORKFLOW_KEYS=(contents id-token)

is_allowed_workflow_key() {
    local key="$1"
    local allowed
    for allowed in "${ALLOWED_WORKFLOW_KEYS[@]}"; do
        if [[ $key == "$allowed" ]]; then
            return 0
        fi
    done
    return 1
}

# Extract permission keys declared at workflow scope (root permissions: block).
# Prints one key per line, or nothing when no workflow-level block exists.
extract_workflow_permission_keys() {
    local file="$1"
    awk '
    BEGIN { in_perms = 0 }
    /^permissions:[[:space:]]*$/ { in_perms = 1; next }
    in_perms {
      if ($0 ~ /^[^[:space:]]/) { exit }
      if ($0 ~ /^  [A-Za-z0-9_-]+:[[:space:]]*/) {
        key = $1
        sub(/:$/, "", key)
        print key
      }
    }
  ' "$file"
}

errors=0

while IFS= read -r file; do
    [[ -n $file ]] || continue
    basename="$(basename "$file")"

    while IFS= read -r key; do
        [[ -n $key ]] || continue
        if ! is_allowed_workflow_key "$key"; then
            echo "ERROR: $basename declares workflow-level permission '$key' (only contents and id-token are allowed at workflow scope)" >&2
            errors=$((errors + 1))
        fi
    done < <(extract_workflow_permission_keys "$file" || true)

done < <(find "$WORKFLOWS_DIR" -maxdepth 1 -name 'reusable_*.yaml' | sort)

if ((errors > 0)); then
    echo "Found $errors reusable workflow permission issue(s)." >&2
    exit 1
fi

echo "All reusable workflow permission scopes are valid."
