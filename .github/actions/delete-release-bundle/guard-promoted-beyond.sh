#!/usr/bin/env bash
# Refuse to delete a release bundle version that has been promoted beyond DEV.
# Matches tf-artifactory cleanup_exclude_downstream_of_dev (TEST, STAGE, PREVIEW, INTERNAL, PROD).
set -euo pipefail

bundle_name="${1:?bundle name required}"
bundle_version="${2:?bundle version required}"
jf_project="${3:?jf project required}"
guard_label="${4:-promotion guard}"

records_path="/lifecycle/api/v2/promotion/records/${bundle_name}?project=${jf_project}&filter_by=${bundle_version}&order_by=created_millis&order_asc=true"
echo "${guard_label}: checking promotion records for ${bundle_name}/${bundle_version}..."
records_json='{"promotions":[]}'
set +e
fetched_records=$(jf rt curl -X GET "$records_path" -H "Accept: application/json" 2>jfrog-error.log)
status=$?
set -e

if [ "$status" -ne 0 ]; then
    error_text="$(<jfrog-error.log)"
    if [[ $error_text == *"404"* || $error_text == *"not found"* || $fetched_records == *"404"* ]]; then
        echo "No existing release bundle promotion records found."
        exit 0
    fi
    echo "::error::Failed to fetch promotion records for ${bundle_name}/${bundle_version}."
    echo "$error_text"
    exit "$status"
fi

records_json="$fetched_records"
echo "$records_json" | jq '.'

if echo "$records_json" | jq -e '.errors? | length > 0' >/dev/null; then
    if echo "$records_json" | jq -e '.errors[]? | (.status | tostring) == "404"' >/dev/null; then
        echo "::warning::Promotion records endpoint returned 404; treating this as no existing promotion records."
        exit 0
    fi
    echo "::error::Failed to fetch promotion records for ${bundle_name}/${bundle_version}."
    exit 1
fi

higher_envs=$(echo "$records_json" | jq -r --arg version "$bundle_version" '
  [(.promotions // [])[]?
    | select((.release_bundle_version // .releaseBundleVersion // .version // "") == $version)
    | select((.status // "COMPLETED") == "COMPLETED")
    | (.environment // .target_environment // .targetEnvironment // empty)
    | select(. == "TEST" or . == "STAGE" or . == "PREVIEW" or . == "INTERNAL" or . == "PROD")]
  | unique
  | join(", ")
')
if [ -n "$higher_envs" ]; then
    echo "::error::Release bundle ${bundle_name}/${bundle_version} already promoted beyond DEV (${higher_envs}). Refusing to delete."
    exit 1
fi

existing_envs=$(echo "$records_json" | jq -r --arg version "$bundle_version" '
  [(.promotions // [])[]?
    | select((.release_bundle_version // .releaseBundleVersion // .version // "") == $version)
    | select((.status // "COMPLETED") == "COMPLETED")
    | (.environment // .target_environment // .targetEnvironment // empty)]
  | unique
  | join(", ")
')
if [ -n "$existing_envs" ]; then
    echo "Existing release bundle promotions (${guard_label}): ${existing_envs}."
else
    echo "No existing release bundle promotions found (${guard_label})."
fi
