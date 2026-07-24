#!/usr/bin/env bash
# Setup helpers for pr-hygiene bats tests

# Default allowlist patterns (must match reusable_pr-hygiene.yml)
# shellcheck disable=SC2034
DEFAULT_PATTERNS=(
        '^[a-zA-Z]+\(deps[^)]*\):'
        '^\[StepSecurity\]'
        '^[Rr]evert "'
        '^revert:'
)

# Check if a title matches any patterns in the given array
# Usage: title_matches_patterns "PR title" "${patterns[@]}"
title_matches_patterns() {
        local title="$1"
        shift
        local patterns=("$@")

        for pattern in "${patterns[@]}"; do
                [[ -z $pattern ]] && continue
                if echo "$title" | grep -qE "$pattern"; then
                        return 0
                fi
        done
        return 1
}

# Extract JIRA ticket from a PR title using the same regex as the workflow
# Usage: extract_jira_ticket "PR title"
extract_jira_ticket() {
        local title="$1"
        echo "$title" | grep -oP '^[a-z]+(\([a-z0-9-_]+\))?(!)?: \[\K[A-Z]{2,10}-[0-9]+(?=\] )' | head -1
}

# Extract the conventional commit type from a PR title
# Usage: extract_commit_type "PR title"
extract_commit_type() {
        local title="$1"
        echo "$title" | grep -oP '^[a-z]+' | head -1
}

# Check if a commit type requires JIRA based on the required-types list
# Usage: type_requires_jira "feat" "feat, fix, docs, ci, refactor"
# shellcheck disable=SC2034
DEFAULT_JIRA_REQUIRED_TYPES="feat, fix, docs, ci, refactor"

type_requires_jira() {
        local commit_type="$1"
        local required_types="$2"

        [ -z "$required_types" ] && return 1

        IFS=',' read -ra types <<<"$required_types"
        for t in "${types[@]}"; do
                t=$(echo "$t" | xargs)
                if [ "$t" = "$commit_type" ]; then
                        return 0
                fi
        done
        return 1
}
