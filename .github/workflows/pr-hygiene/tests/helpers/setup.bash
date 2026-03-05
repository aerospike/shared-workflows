#!/usr/bin/env bash
# Setup helpers for pr-hygiene bats tests

# Default allowlist patterns (must match reusable_pr-hygiene.yml)
# shellcheck disable=SC2034
DEFAULT_PATTERNS=(
        '^Build\(deps.*\):'
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
        echo "$title" | grep -oP '^[a-z]+(\([a-z0-9-]+\))?: \[\K[A-Z]{2,10}-[0-9]+(?=\] )' | head -1
}
