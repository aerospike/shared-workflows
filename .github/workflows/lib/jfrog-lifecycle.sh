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
