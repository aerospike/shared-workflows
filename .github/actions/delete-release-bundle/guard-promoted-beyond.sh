#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/../../workflows/lib/jfrog-lifecycle.sh"

bundle_name="${1:?bundle name required}"
bundle_version="${2:?bundle version required}"
jf_project="${3:?jf project required}"
bundle="${bundle_name}/${bundle_version}"

records=$(jfrog_promotion_records "$bundle_name" "$bundle_version" "$jf_project") || {
    echo "::error::Could not read the promotion records for ${bundle}. Refusing to delete."
    exit 1
}

# A promotion still in progress counts: it may yet complete.
beyond_dev=$(jq -r '[.promotions[] | select(.status != "FAILED" and .environment != "DEV") | .environment]
    | unique | join(",")' <<<"$records")
if [[ -n $beyond_dev ]]; then
    echo "::error::${bundle} is promoted, or being promoted, beyond DEV (${beyond_dev}). Refusing to delete."
    exit 1
fi
echo "${bundle} is not promoted beyond DEV."
