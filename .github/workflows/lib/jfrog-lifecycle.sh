#!/usr/bin/env bash

jfrog_uri_encode() {
    jq -rn --arg s "$1" '$s | @uri'
}

# jf rt curl is Artifactory-scoped and 404s on a /lifecycle path.
jfrog_lifecycle_get() (
    # xtrace would print the token.
    set +x
    local config base token
    config=$(jf config export | base64 -d) || {
        echo "Error: could not read the JFrog CLI configuration" >&2
        return 1
    }
    base=$(jq -r '.url // empty' <<<"$config")
    token=$(jq -r '.accessToken // empty' <<<"$config")
    if [[ -z $base || -z $token ]]; then
        echo "Error: the JFrog CLI has no platform URL and access token configured" >&2
        return 1
    fi
    # -H would put the token in argv.
    curl -sS --fail --connect-timeout 10 --max-time 60 --retry 3 \
        --config - "${base%/}/$1" <<CURLRC
header = "Authorization: Bearer ${token}"
CURLRC
)

# An empty list means "not promoted", so an unreadable response must fail.
jfrog_promotion_records() {
    local name="$1" version="$2" project="$3" path records
    path="lifecycle/api/v2/promotion/records/$(jfrog_uri_encode "$name")/$(jfrog_uri_encode "$version")"
    path+="?project=$(jfrog_uri_encode "$project")&limit=1000"
    records=$(jfrog_lifecycle_get "$path") || {
        echo "Error: could not read promotion records for ${name}/${version}" >&2
        return 1
    }
    jq -e '.promotions | type == "array"' >/dev/null 2>&1 <<<"$records" || {
        echo "Error: unexpected promotion records for ${name}/${version}: ${records}" >&2
        return 1
    }
    printf '%s\n' "$records"
}

# Prints every version of a bundle with a completed promotion to a stage.
jfrog_versions_at_stage() {
    local name="$1" project="$2" stage="$3" path records versions
    path="lifecycle/api/v2/promotion/records/$(jfrog_uri_encode "$name")"
    path+="?project=$(jfrog_uri_encode "$project")&limit=1000"
    records=$(jfrog_lifecycle_get "$path") || {
        echo "Error: could not read promotion records for ${name}" >&2
        return 1
    }
    versions=$(jq -r --arg stage "$stage" 'if (.promotions | type) == "array" and .total == (.promotions | length)
        then .promotions[] | select(.status == "COMPLETED" and .environment == $stage) | .release_bundle_version
        else error("unexpected records") end' <<<"$records") || {
        echo "Error: unexpected or truncated promotion records for ${name}" >&2
        return 1
    }
    [[ -z $versions ]] || LC_ALL=C sort -u <<<"$versions"
}

# Prints the artifact paths in the release bundle or promotion record at an API path.
jfrog_record_artifact_paths() {
    local record paths
    record=$(jfrog_lifecycle_get "$1") || return 1
    paths=$(jq -r 'if (.artifacts | type) == "array"
            and (.total_artifacts_count // (.artifacts | length)) == (.artifacts | length)
        then .artifacts[].path else error("unexpected record") end' <<<"$record") || {
        echo "Error: unexpected record at $1: ${record}" >&2
        return 1
    }
    [[ -z $paths ]] || LC_ALL=C sort -u <<<"$paths"
}

jfrog_bundle_artifact_paths() {
    jfrog_record_artifact_paths "lifecycle/api/v2/release_bundle/records/$(jfrog_uri_encode "$1")/$(jfrog_uri_encode "$2")?project=$(jfrog_uri_encode "$3")"
}

# A promotion record's paths start with the target repo; a bundle record's do not.
jfrog_promotion_artifact_paths() {
    jfrog_record_artifact_paths "lifecycle/api/v2/promotion/records/$(jfrog_uri_encode "$1")/$(jfrog_uri_encode "$2")/$(jfrog_uri_encode "$4")?project=$(jfrog_uri_encode "$3")" |
        sed 's|^[^/]*/||' | LC_ALL=C sort -u
}
