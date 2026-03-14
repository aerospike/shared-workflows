#!/usr/bin/env bash
# upload_utils.sh - Shared upload helper functions for artifact deployment
#
# Required globals (set by entrypoint.sh before sourcing):
#   BUILD_NAME, ARTIFACT_BUILD_NUMBER, PROJECT, DRY_RUN
#   run() function must be defined
#   TYPE_EXTENSIONS, TYPE_COMPANIONS, TYPE_REPO, TYPE_STRUCT_DIR arrays from type_registry.sh

# --- Upload helpers ---

# Wraps `jf rt upload` with the standard flags that every upload needs.
# Usage: jf_upload <file> <repo> [extra-flags...]
# Automatically adds: --flat=false --build-name --build-number --project
jf_upload() {
    local file="$1"
    local repo="$2"
    shift 2
    run jf rt upload "$file" "$repo" --flat=false \
        --build-name="$BUILD_NAME" \
        --build-number="$ARTIFACT_BUILD_NUMBER" \
        --project="$PROJECT" \
        "$@"
}

# Upload companion files (signatures, checksums, etc.) that exist alongside a primary file.
# Companions are defined per type in TYPE_COMPANIONS.
# Usage: upload_companions <file> <repo> <type>
upload_companions() {
    local file="$1"
    local repo="$2"
    local type="$3"
    local companions="${TYPE_COMPANIONS[$type]-}"
    [[ -z $companions ]] && return 0
    for suffix in $companions; do
        if [[ -f "$file$suffix" ]]; then
            echo "  Uploading companion: $file$suffix" >&2
            jf_upload "$file$suffix" "$repo"
        fi
    done
}

# --- Structuring helpers ---

# Discover primary files by extension and gather them WITH their companions into structured dirs.
# This is the key function that treats artifacts as groups, not individual files.
# Usage: discover_and_process <pattern> <label> <processor> <dest> [type]
#   pattern   - find glob (e.g., "*.deb")
#   label     - log label (e.g., "DEB")
#   processor - function to call per file (e.g., process_deb)
#   dest      - destination directory
#   type      - optional type key for companion lookup
discover_and_process() {
    local pattern="$1"
    local label="$2"
    local processor="$3"
    local dest="$4"
    local type="${5-}"

    while IFS= read -r -d '' file; do
        [[ -f $file ]] || continue
        echo "Processing $label: $file" >&2

        # Processor returns the target path on stdout (all logging goes to stderr)
        local target_path
        target_path=$("$processor" "$file" "$dest")

        # Copy companion files to the same directory as the primary
        if [[ -n $type && -n $target_path ]]; then
            local target_dir
            target_dir=$(dirname "$target_path")
            local companions="${TYPE_COMPANIONS[$type]-}"
            for suffix in $companions; do
                if [[ -f "$file$suffix" ]]; then
                    echo "  Gathering companion: $file$suffix" >&2
                    cp -v "$file$suffix" "$target_dir/" >&2
                fi
            done
        fi
    done < <(find build-artifacts -name "$pattern" -print0)
}

# --- Upload dispatch ---

# Default upload loop for simple types (deb, rpm).
# Complex types (jar, nupkg, generic) provide their own upload function override.
# The convention is: if upload_TYPE_packages() exists, it is called instead.
# Otherwise this generic loop handles find -> props -> upload -> companions.
# Usage: upload_type <type>
upload_type() {
    local type="$1"
    local repo="$PROJECT-${TYPE_REPO[$type]}"

    # Check for a custom upload function override
    if type -t "upload_${type}_packages" &>/dev/null; then
        "upload_${type}_packages"
        return
    fi
    if type -t "upload_${type}_files" &>/dev/null; then
        "upload_${type}_files"
        return
    fi

    echo "Uploading ${type^^} packages to JFrog..." >&2

    while IFS= read -r -d '' file; do
        [[ -f $file ]] || continue

        local -a extra_flags=()

        # get_TYPE_props <file> returns target-props string
        if type -t "get_${type}_props" &>/dev/null; then
            local props
            props=$("get_${type}_props" "$file")
            [[ -n $props ]] && extra_flags+=(--target-props "$props")
        fi

        # get_TYPE_extra_flags <file> returns additional jf flags
        if type -t "get_${type}_extra_flags" &>/dev/null; then
            local -a ef=()
            read -ra ef < <("get_${type}_extra_flags" "$file")
            extra_flags+=("${ef[@]}")
        fi

        jf_upload "$file" "$repo" "${extra_flags[@]}"
        upload_companions "$file" "$repo" "$type"
    done < <(find . -name "${TYPE_EXTENSIONS[$type]}" -print0)
}
