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

# jf rt curl is Artifactory-scoped and 404s on a /lifecycle path.
jfrog_lifecycle_get() (
    set +x
    local path="$1" cfg base token
    cfg=$(jfrog_platform_config) || return 1
    IFS=$'\t' read -r base token <<<"$cfg"

    # -H would put the token in argv.
    curl -sS --fail --config - "${base}/${path#/}" <<CURLRC
header = "Authorization: Bearer ${token}"
CURLRC
)

# A bundle with no promotions answers 200 with an empty array, so an unreadable response must
# fail rather than read as "nothing is promoted". The same is true of a page that was not
# fetched.
jfrog_promotion_records() {
    local bundle_name="$1" project="$2" offset=0 pages="" page count total
    while :; do
        page=$(jfrog_lifecycle_get "lifecycle/api/v2/promotion/records/${bundle_name}?project=${project}&limit=1000&offset=${offset}") || {
            echo "Error: could not read promotion records for ${bundle_name}" >&2
            return 1
        }
        if ! jq -e 'has("promotions")' >/dev/null 2>&1 <<<"$page"; then
            echo "Error: unexpected promotion records response for ${bundle_name}: ${page}" >&2
            return 1
        fi
        pages+="${page}"$'\n'
        count=$(jq '.promotions | length' <<<"$page")
        total=$(jq '.total // 0' <<<"$page")
        offset=$((offset + count))
        ((count > 0 && offset < total)) || break
    done
    jq -s '{promotions: (map(.promotions) | add // [])}' <<<"$pages"
}

# Field names vary across JFrog responses, so read every spelling we have seen.
jfrog_promotion_stages() {
    local records="$1" version="$2"
    echo "$records" | jq -r --arg version "$version" '
      [(.promotions // [])[]?
        | select((.status // "COMPLETED") == "COMPLETED")
        | select((.release_bundle_version // .releaseBundleVersion // .version // "") == $version)
        | (.environment // .target_environment // .targetEnvironment // empty)]
      | unique | .[]'
}
