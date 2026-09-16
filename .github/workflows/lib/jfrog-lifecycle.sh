#!/usr/bin/env bash
# jfrog-lifecycle.sh - Reads from the JFrog Lifecycle (Release Bundle v2) API.

# jf rt curl is Artifactory-scoped and 404s on a /lifecycle path.
jfrog_lifecycle_get() {
    local path="$1" config base token
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

    # The header goes in a config file so the token stays out of argv and xtrace.
    curl -sS --fail-with-body --config - "${base%/}/${path#/}" <<CURLRC
header = "Authorization: Bearer ${token}"
CURLRC
}

# A bundle with no promotions answers 200 with an empty array, so any unreadable
# response is a failure and must not be mistaken for "nothing is promoted".
jfrog_promotion_records() {
    local bundle_name="$1" project="$2" out
    out=$(jfrog_lifecycle_get "lifecycle/api/v2/promotion/records/${bundle_name}?project=${project}") || {
        echo "Error: could not read promotion records for ${bundle_name}" >&2
        return 1
    }
    if ! echo "$out" | jq -e 'has("promotions")' >/dev/null 2>&1; then
        echo "Error: unexpected promotion records response for ${bundle_name}: ${out}" >&2
        return 1
    fi
    echo "$out"
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

jfrog_versions_at_stage() {
    local records="$1" stage="$2"
    echo "$records" | jq -r --arg stage "$stage" '
      [(.promotions // [])[]?
        | select((.status // "COMPLETED") == "COMPLETED")
        | select((.environment // .target_environment // .targetEnvironment // "") == $stage)
        | (.release_bundle_version // .releaseBundleVersion // .version // empty)]
      | unique | .[]'
}
