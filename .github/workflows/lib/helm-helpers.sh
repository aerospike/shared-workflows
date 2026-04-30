#!/usr/bin/env bash
# helm-helpers.sh - Shared Helm chart helpers.
#
# Sourced by both deploy-artifacts (for type detection + metadata extraction)
# and sign-artifacts (for .prov generation). Keeping the helpers in one place
# avoids drift between the two stages.
#
# This file should contain only pure helpers (no globals, no side effects on source).

# Extract Chart.yaml content from a packaged Helm chart .tgz.
# Helm packages place Chart.yaml at the root of a single top-level directory:
# <chart-name>/Chart.yaml.
# Args: <tgz_file>
# Returns: the Chart.yaml content on stdout, or returns 1 if not found.
_extract_helm_chart_yaml() {
    local file="$1"
    local chart_path
    chart_path=$(tar -tzf "$file" 2>/dev/null | grep -E '^[^/]+/Chart\.yaml$' | head -n1) || return 1
    [ -z "$chart_path" ] && return 1
    tar -xOzf "$file" "$chart_path" 2>/dev/null
}

# Returns 0 if the given .tgz/.tar.gz is a packaged Helm chart.
# A packaged chart has Chart.yaml at the root of a single top-level directory,
# declaring apiVersion (v1 or v2) plus non-empty name and version.
# Args: <file>
is_helm_chart() {
    local file="$1"
    case "$file" in
    *.tgz | *.tar.gz) ;;
    *) return 1 ;;
    esac
    local chart_yaml
    chart_yaml=$(_extract_helm_chart_yaml "$file") || return 1
    grep -qE '^apiVersion:[[:space:]]*v[12]\b' <<<"$chart_yaml" || return 1
    grep -qE '^name:[[:space:]]*[^[:space:]]' <<<"$chart_yaml" || return 1
    grep -qE '^version:[[:space:]]*[^[:space:]]' <<<"$chart_yaml" || return 1
}
