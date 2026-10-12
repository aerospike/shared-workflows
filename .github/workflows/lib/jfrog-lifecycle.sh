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

# An empty list means "not promoted", so an unreadable or incomplete response must fail.
jfrog_promotion_records() {
    local name="$1" version="$2" project="$3" path records
    path="lifecycle/api/v2/promotion/records/$(jfrog_uri_encode "$name")/$(jfrog_uri_encode "$version")"
    path+="?project=$(jfrog_uri_encode "$project")&limit=1000"
    records=$(jfrog_lifecycle_get "$path") || {
        echo "Error: could not read promotion records for ${name}/${version}" >&2
        return 1
    }
    jq -e '(.promotions | type) == "array"
        and all(.promotions[]; (.environment | type) == "string" and (.status | type) == "string")
        and (.total // 0) <= (.promotions | length)' >/dev/null 2>&1 <<<"$records" || {
        echo "Error: unexpected promotion records for ${name}/${version}: ${records}" >&2
        return 1
    }
    printf '%s\n' "$records"
}
