#!/usr/bin/env bash
# Validate Upload Maven bundle metadata step configuration in reusable_deploy-artifacts.yaml.
#
# Ensures the hidden dotfile .maven-bundle-metadata.json is uploaded with
# include-hidden-files: true and fails loudly when missing (if-no-files-found: error).

set -euo pipefail

check_bundle_metadata_upload_step() {
    local file="$1"
    local block

    if [[ ! -f $file ]]; then
        echo "Error: file not found: $file" >&2
        return 1
    fi

    block="$(awk '
        /^      - name: Upload Maven bundle metadata$/ { capture = 1 }
        capture {
            print
            if ($0 ~ /^      - name: / && $0 !~ /Upload Maven bundle metadata/) { exit }
        }
    ' "$file")"

    if [[ -z $block ]]; then
        echo "Error: Upload Maven bundle metadata step not found in $file" >&2
        return 1
    fi

    local missing=0

    if ! grep -q 'id: upload-bundle-metadata' <<<"$block"; then
        echo "Error: upload step missing required setting: id: upload-bundle-metadata" >&2
        missing=1
    fi
    if ! grep -q 'include-hidden-files: true' <<<"$block"; then
        echo "Error: upload step missing required setting: include-hidden-files: true" >&2
        missing=1
    fi
    if ! grep -q 'if-no-files-found: error' <<<"$block"; then
        echo "Error: upload step missing required setting: if-no-files-found: error" >&2
        missing=1
    fi
    if ! grep -q 'structured_build_artifacts/.maven-bundle-metadata.json' <<<"$block"; then
        echo "Error: upload step missing required path to .maven-bundle-metadata.json" >&2
        missing=1
    fi

    if ! grep -q 'steps.upload-bundle-metadata.outcome' "$file"; then
        echo "Error: bundle-metadata outputs must reference upload-bundle-metadata outcome" >&2
        missing=1
    fi
    if ! grep -q 'steps.bundle-metadata-state.outputs.artifact-name' "$file"; then
        echo "Error: bundle-metadata-artifact-name must reference bundle-metadata-state" >&2
        missing=1
    fi

    if ! grep -q 'maven_module_count // 0' "$file"; then
        echo "Error: record step must skip upload when maven_module_count is zero" >&2
        missing=1
    fi

    [[ $missing -eq 0 ]]
}

if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    target="${1:-.github/workflows/reusable_deploy-artifacts.yaml}"
    if check_bundle_metadata_upload_step "$target"; then
        echo "Bundle metadata upload step configuration is valid: $target"
    else
        exit 1
    fi
fi
