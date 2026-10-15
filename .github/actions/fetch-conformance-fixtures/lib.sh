#!/usr/bin/env bash
# Pure helpers for fetch-conformance-fixtures. No JFrog or filesystem side effects.

error() {
    local reason="${1-}"
    if [[ -n $reason ]]; then
        echo "Error: $reason" >&2
    else
        echo "Error" >&2
    fi
    exit 1
}

is_dry_run() {
    [[ ${DRY_RUN:-false} == true ]]
}

validate_semver() {
    local version=$1
    if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        error "version must be MAJOR.MINOR.PATCH with no v prefix (got: '$version')"
    fi
}

validate_token() {
    local label=$1
    local value=$2
    if [[ ! $value =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        error "$label must be a single path segment (got: '$value')"
    fi
}

validate_destination() {
    local destination=$1
    if [[ -z $destination || $destination == . ]]; then
        error "destination must be a subdirectory of the workspace (got: '$destination')"
    fi
    if [[ $destination == /* ]]; then
        error "destination must be relative to the workspace (got: '$destination')"
    fi
    if [[ $destination == *".."* ]]; then
        error "destination must not contain '..' (got: '$destination')"
    fi
}

# Artifactory path of the release zip published by aerospike-client-conformance.
artifact_repo_path() {
    local project=$1
    local package=$2
    local version=$3
    printf '%s-generic-dev-local/%s/%s/%s-%s.zip\n' \
        "$project" "$package" "$version" "$package" "$version"
}

resolve_destination() {
    local destination=$1
    local workspace=${GITHUB_WORKSPACE:-$PWD}
    validate_destination "$destination"
    printf '%s/%s\n' "$workspace" "$destination"
}
