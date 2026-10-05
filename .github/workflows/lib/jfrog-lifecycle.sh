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

jfrog_completed_promotion_ids() {
    jq -r --arg stage "$2" '.promotions[]
        | select(.status == "COMPLETED" and .environment == $stage)
        | .created_millis // error("promotion record without created_millis")' <<<"$1"
}

# Prints the version's artifact paths, relative to their repo.
jfrog_bundle_artifact_paths() {
    local bundle_name="$1" version="$2" project="$3" path record paths
    path="lifecycle/api/v2/release_bundle/records/$(jfrog_uri_encode "$bundle_name")/$(jfrog_uri_encode "$version")"
    path+="?project=$(jfrog_uri_encode "$project")"
    record=$(jfrog_lifecycle_get "$path") || {
        echo "Error: could not read the artifacts of ${bundle_name}/${version}" >&2
        return 1
    }
    paths=$(jq -r '
        if (.artifacts | type) == "array"
            and all(.artifacts[]; (.path | type) == "string")
            and (.total_artifacts_count // (.artifacts | length)) == (.artifacts | length)
        then .artifacts[].path
        else error("unexpected release bundle record") end' <<<"$record") || {
        echo "Error: unexpected release bundle record for ${bundle_name}/${version}: ${record}" >&2
        return 1
    }
    [[ -z $paths ]] || LC_ALL=C sort -u <<<"$paths"
}

# Prints the artifact paths one promotion placed, relative to their repo. Unlike a bundle
# record's paths, a promotion record's paths start with the target repo.
jfrog_promotion_artifact_paths() {
    local bundle_name="$1" version="$2" project="$3" created_millis="$4" path detail paths
    path="lifecycle/api/v2/promotion/records/$(jfrog_uri_encode "$bundle_name")/$(jfrog_uri_encode "$version")"
    path+="/$(jfrog_uri_encode "$created_millis")?project=$(jfrog_uri_encode "$project")"
    detail=$(jfrog_lifecycle_get "$path") || {
        echo "Error: could not read promotion ${created_millis} of ${bundle_name}/${version}" >&2
        return 1
    }
    paths=$(jq -r '
        if (.artifacts | type) == "array" and all(.artifacts[]; (.path | type) == "string")
        then .artifacts[].path | sub("^[^/]+/"; "")
        else error("unexpected promotion record") end' <<<"$detail") || {
        echo "Error: unexpected promotion record ${created_millis} for ${bundle_name}/${version}: ${detail}" >&2
        return 1
    }
    [[ -z $paths ]] || LC_ALL=C sort -u <<<"$paths"
}
