#!/usr/bin/env bash
# Validate permission scoping on reusable_*.yaml workflows.
#
# Policy:
# - Workflow-level permissions may only grant contents: read and id-token: write.
# - Elevated permissions (actions, packages, attestations, ...) must be job-scoped.
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

# Return 0 when the file declares job-level permissions for the given key.
has_job_scoped_permission() {
    local file="$1"
    local perm_key="$2"
    awk -v want="$perm_key" '
    BEGIN { in_jobs = 0; in_job_perms = 0; found = 0 }
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    in_jobs {
      if ($0 ~ /^[^[:space:]]/) { exit }
      if ($0 ~ /^    permissions:[[:space:]]*$/) {
        in_job_perms = 1
        next
      }
      if (in_job_perms && $0 ~ /^      [A-Za-z0-9_-]+:[[:space:]]*/) {
        key = $1
        sub(/:$/, "", key)
        if (key == want) {
          found = 1
        }
      }
      if (in_job_perms && $0 ~ /^    [A-Za-z0-9_-]+:[[:space:]]*$/ && $0 !~ /^      /) {
        in_job_perms = 0
      }
    }
    END {
      if (found) {
        exit 0
      }
      exit 1
    }
  ' "$file"
}

errors=0

while IFS= read -r file; do
    [[ -n $file ]] || continue
    basename="$(basename "$file")"
    has_workflow_keys=false

    while IFS= read -r key; do
        [[ -n $key ]] || continue
        has_workflow_keys=true
        if ! is_allowed_workflow_key "$key"; then
            echo "ERROR: $basename declares workflow-level permission '$key' (only contents and id-token are allowed at workflow scope)" >&2
            errors=$((errors + 1))
        fi
    done < <(extract_workflow_permission_keys "$file" || true)

    if [[ $has_workflow_keys == false ]]; then
        continue
    fi

    case "$basename" in
    reusable_deploy-artifacts.yaml)
        if ! has_job_scoped_permission "$file" "actions"; then
            echo "ERROR: $basename must declare job-scoped actions: write on the deploy job" >&2
            errors=$((errors + 1))
        fi
        ;;
    reusable_create-release-bundle.yaml)
        if ! has_job_scoped_permission "$file" "actions"; then
            echo "ERROR: $basename must declare job-scoped actions: read on the create-release-bundle job" >&2
            errors=$((errors + 1))
        fi
        ;;
    esac
done < <(find "$WORKFLOWS_DIR" -maxdepth 1 -name 'reusable_*.yaml' | sort)

if ((errors > 0)); then
    echo "Found $errors reusable workflow permission issue(s)." >&2
    exit 1
fi

echo "All reusable workflow permission scopes are valid."
