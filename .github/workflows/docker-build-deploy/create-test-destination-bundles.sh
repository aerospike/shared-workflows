#!/usr/bin/env bash
set -euo pipefail

PROJECT="test"
BUNDLE_NAME="test-docker-release"
REPOSITORY="test-release-bundles-v2"
IMAGE="test-image"

error() {
    echo "Error: ${1-}" >&2
    exit 1
}

show_help() {
    cat >&2 <<EOF
Usage: $0 [--dry-run]

Print the ${BUNDLE_NAME} versions for Quay and OpenShift, or refuse when one
of those versions already exists in ${REPOSITORY}.

  --dry-run    Print the versions and do not call jf
  --help, -h   Show this help
EOF
}

bundle_lines() {
    printf '%s %s %s %s\n' \
        quay-1 "$IMAGE" 1 quay \
        openshift-1 "$IMAGE" 1 openshift \
        quay-openshift-1 "$IMAGE" 1 "quay,openshift" \
        openshift-2 "$IMAGE" 2 openshift
}

DRY_RUN=false
while [[ $# -gt 0 ]]; do
    case $1 in
    --dry-run)
        DRY_RUN=true
        shift
        ;;
    --help | -h)
        show_help
        exit 0
        ;;
    *)
        error "unknown option: $1"
        ;;
    esac
done

if [[ $DRY_RUN == true ]]; then
    bundle_lines
    exit 0
fi

command -v jq >/dev/null 2>&1 || error "jq is required to read the release bundle search response"

response=$(jf release-bundle-search versions "$BUNDLE_NAME" \
    --project="$PROJECT" --format=json)

if ! jq -e '.release_bundles | type == "array"' >/dev/null <<<"$response"; then
    error "unexpected release bundle search response for ${BUNDLE_NAME}"
fi

found=0
while read -r version; do
    [[ -n $version ]] || continue
    if jq -e --arg version "$version" \
        '.release_bundles | map(select(.release_bundle_version == $version)) | length > 0' \
        >/dev/null <<<"$response"; then
        echo "Error: ${BUNDLE_NAME}@${version} already exists in ${REPOSITORY}. Not creating another copy." >&2
        found=1
    fi
done < <(bundle_lines | awk '{print $1}' | awk '!seen[$0]++')

if [[ $found -ne 0 ]]; then
    exit 1
fi

echo "No ${BUNDLE_NAME} version from this list exists in ${REPOSITORY}." >&2
