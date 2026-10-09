#!/usr/bin/env bash

# Prints "<base>\t<token>". A token passed as an argument would show in the process list.
jfrog_platform_config() (
    # xtrace would print the token.
    set +x
    local config base token
    config=$(jf config export) || {
        echo "Error: could not read the JFrog CLI configuration" >&2
        return 1
    }
    base=$(printf '%s' "$config" | base64 -d | jq -r '.url // empty')
    token=$(printf '%s' "$config" | base64 -d | jq -rj '.accessToken // empty')
    if [[ -z $base || -z $token ]]; then
        echo "Error: the JFrog CLI has no platform URL and access token configured" >&2
        return 1
    fi
    printf '%s\t%s' "${base%/}" "$token"
)

jfrog_uri_encode() {
    jq -rn --arg s "$1" '$s | @uri'
}

# jf rt curl is Artifactory-scoped and 404s on a /lifecycle path.
jfrog_lifecycle_get() (
    set +x
    local path="$1" cfg base token
    cfg=$(jfrog_platform_config) || return 1
    IFS=$'\t' read -r base token <<<"$cfg"

    # -H would put the token in argv.
    curl -sS --fail --connect-timeout 10 --max-time 60 --retry 3 \
        --config - "${base}/${path#/}" <<CURLRC
header = "Authorization: Bearer ${token}"
CURLRC
)

# A version with no promotions answers 200 with an empty array, so a response that cannot be
# read in full must fail rather than read as "nothing is promoted".
jfrog_promotion_records() {
    local bundle_name="$1" version="$2" project="$3" path records
    path="lifecycle/api/v2/promotion/records/$(jfrog_uri_encode "$bundle_name")/$(jfrog_uri_encode "$version")"
    path+="?project=$(jfrog_uri_encode "$project")&limit=1000"
    records=$(jfrog_lifecycle_get "$path") || {
        echo "Error: could not read promotion records for ${bundle_name}/${version}" >&2
        return 1
    }
    if ! jq -e '
        (.promotions | type) == "array"
        and all(.promotions[]; (.environment | type) == "string" and (.status | type) == "string")
        and (.total // 0) <= (.promotions | length)' >/dev/null 2>&1 <<<"$records"; then
        echo "Error: unexpected promotion records response for ${bundle_name}/${version}: ${records}" >&2
        return 1
    fi
    printf '%s\n' "$records"
}

# A promotion that has not failed may still complete, so it counts.
jfrog_stages_not_failed() {
    jq -r '[.promotions[] | select(.status != "FAILED" and .status != "REJECTED") | .environment]
        | unique | .[]' <<<"$1"
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
