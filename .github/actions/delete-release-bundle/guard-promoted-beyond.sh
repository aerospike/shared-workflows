#!/usr/bin/env bash
# Refuse to delete a release bundle version that is promoted, or being promoted, to any stage
# other than DEV.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../../workflows/lib/jfrog-lifecycle.sh"

bundle_name="${1:?bundle name required}"
bundle_version="${2:?bundle version required}"
jf_project="${3:?jf project required}"
guard_label="${4:-promotion guard}"

echo "${guard_label}: checking promotion records for ${bundle_name}/${bundle_version}..."

if ! records=$(jfrog_promotion_records "$bundle_name" "$bundle_version" "$jf_project"); then
    echo "::error::${guard_label}: could not verify promotions for ${bundle_name}/${bundle_version}. Refusing to delete."
    exit 1
fi

stages=$(jfrog_stages_not_failed "$records")
beyond_dev=$(grep -vFx -e DEV -e '' <<<"$stages" | paste -sd, - || true)

if [[ -n $beyond_dev ]]; then
    echo "::error::Release bundle ${bundle_name}/${bundle_version} is promoted, or being promoted, beyond DEV (${beyond_dev}). Refusing to delete. Remove the promotion first if this is intended."
    exit 1
fi

if [[ -n $stages ]]; then
    echo "${guard_label}: existing promotions: $(echo "$stages" | paste -sd, -)."
else
    echo "${guard_label}: no existing promotions."
fi
