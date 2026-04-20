#!/usr/bin/env bash
# type_detection.sh - Content-based artifact type detection during structuring
#
# Required (sourced by entrypoint.sh after package_utils.sh, type_registry.sh, upload_utils.sh):
#   CONTENT_DETECT_EXTENSIONS, CONTENT_DETECT_ORDER, TYPE_CONTENT_DETECT, TYPE_STRUCT_DIR
#   gather_companions, manifest_add, process_* helpers from package_utils.sh
#
# Optional: BUILD_ARTIFACTS_DIR (default build-artifacts) — must match copy_to_structured() in package_utils.sh

structure_content_detected_files() {
    local artifacts_root="${BUILD_ARTIFACTS_DIR:-build-artifacts}"
    # Build the find pattern from CONTENT_DETECT_EXTENSIONS
    local -a find_args=()
    for i in "${!CONTENT_DETECT_EXTENSIONS[@]}"; do
        ((i > 0)) && find_args+=(-o)
        find_args+=(-name "${CONTENT_DETECT_EXTENSIONS[$i]}")
    done

    while IFS= read -r -d '' file; do
        [[ -f $file ]] || continue
        local matched=false
        for type in "${CONTENT_DETECT_ORDER[@]}"; do
            local detector="${TYPE_CONTENT_DETECT[$type]}"
            if "$detector" "$file"; then
                echo "Processing ${type^^}: $file" >&2
                local dest="./structured_build_artifacts/${TYPE_STRUCT_DIR[$type]}"
                local processor="process_${type}"
                local target_path
                target_path=$("$processor" "$file" "$dest")
                if [[ -n $target_path ]]; then
                    gather_companions "$file" "$(dirname "$target_path")" "$type"
                    manifest_add "$target_path" "$type"
                fi
                matched=true
                break
            fi
        done
        if [[ $matched == false ]]; then
            echo "Processing generic tarball: $file" >&2
            local target_path
            target_path=$(process_generic "$file" "./structured_build_artifacts/generic")
            if [[ -n $target_path ]]; then
                gather_companions "$file" "$(dirname "$target_path")" "generic"
                manifest_add "$target_path" "generic"
            fi
        fi
    done < <(find "$artifacts_root" \( "${find_args[@]}" \) -print0)
}
