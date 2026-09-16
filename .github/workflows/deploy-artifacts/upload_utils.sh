#!/usr/bin/env bash
# upload_utils.sh - Shared upload helper functions for artifact deployment
#
# Required globals (set by entrypoint.sh before sourcing):
#   BUILD_NAME, ARTIFACT_BUILD_NUMBER, PROJECT, DRY_RUN
#   run() must be defined before this file is sourced (entrypoint defines it first).
#   Call jf_upload only as: run jf_upload <file> <repo> [extra-flags...] so dry-run invokes
#   jf_upload (which logs the real `jf rt upload …` line) instead of calling jf.
#   TYPE_EXTENSIONS, TYPE_COMPANIONS, TYPE_REPO, TYPE_STRUCT_DIR arrays from type_registry.sh

# --- Manifest helpers ---
# The manifest tracks every file placed during structuring so upload functions
# can iterate it instead of re-discovering files with find.
# Format: TSV with columns: relative-path, type

MANIFEST_FILE=""

init_manifest() {
    # Usage: init_manifest [flush]
    MANIFEST_FILE="$(pwd)/structured_build_artifacts/.manifest"
    if [[ ! -f $MANIFEST_FILE || ${1-} == "flush" ]]; then
        : >"$MANIFEST_FILE"
    fi
}

# Add a file to the manifest. Paths are stored as-is (as returned by process functions).
# Skips duplicate path+type lines (e.g. detect_types.sh then entrypoint both structure the same wheel).
manifest_add() {
    local path="$1"
    local type="$2"
    if [[ -f ${MANIFEST_FILE-} ]] && grep -Fxq "${path}"$'\t'"${type}" "$MANIFEST_FILE" 2>/dev/null; then
        return 0
    fi
    printf '%s\t%s\n' "$path" "$type" >>"$MANIFEST_FILE"
}

# Iterate manifest entries for a given type, calling a callback for each file.
# Stored paths like ./structured_build_artifacts/TYPE_DIR/... are converted to
# ./... relative to the type's structured directory (where upload functions run).
# Usage: manifest_for_type <type> <callback>
manifest_for_type() {
    local target_type="$1"
    local callback="$2"
    local struct_dir="${TYPE_STRUCT_DIR[$target_type]:-$target_type}"
    local prefix="./structured_build_artifacts/${struct_dir}/"
    while IFS=$'\t' read -r path type; do
        if [[ $type == "$target_type" ]]; then
            "$callback" "./${path#"$prefix"}"
        fi
    done <"$MANIFEST_FILE"
}

# --- Upload helpers ---

# Wraps `jf rt upload` with the standard flags that every upload needs.
# Usage: run jf_upload <file> <repo> [extra-flags...]
# Automatically adds: --flat=false --build-name --build-number --project
# Must be invoked through run() so dry-run dispatches here instead of echoing `jf_upload …`.
jf_upload() {
    local file="$1"
    local repo="$2"
    shift 2
    if [[ ${DRY_RUN-} == "true" ]]; then
        # Use %s (not %q): %q escapes semicolons in --target-props and breaks bats parsers.
        {
            printf 'Would run: '
            printf '%s ' jf rt upload "$file" "$repo" --flat=false \
                "--build-name=$BUILD_NAME" \
                "--build-number=$ARTIFACT_BUILD_NUMBER" \
                "--project=$PROJECT"
            (($# > 0)) && printf '%s ' "$@"
            printf '\n'
        } >&2
        return 0
    fi
    jf rt upload "$file" "$repo" --flat=false \
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
            run jf_upload "$file$suffix" "$repo"
        fi
    done
}

# --- Structuring helpers ---

# Copy companion files from source location to the structured target directory.
# Usage: gather_companions <source_file> <target_dir> <type>
gather_companions() {
    local source_file="$1"
    local target_dir="$2"
    local type="$3"
    local companions="${TYPE_COMPANIONS[$type]-}"
    [[ -z $companions ]] && return 0
    for suffix in $companions; do
        if [[ -f "$source_file$suffix" ]]; then
            echo "  Gathering companion: $source_file$suffix" >&2
            cp -v "$source_file$suffix" "$target_dir/" >&2
        fi
    done
}

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

        # Processors print one target path per line on stdout (all logging goes to
        # stderr). A processor may place several copies of one artifact, e.g.
        # process_rpm fans a noarch package out across <dist>/<arch> folders.
        local processor_out
        processor_out=$("$processor" "$file" "$dest")

        if [[ -z $type ]]; then
            continue
        fi
        if [[ -z $processor_out ]]; then
            echo "Warning: $label processor returned no target path; artifact not copied to structured tree: $file" >&2
            continue
        fi

        local -a target_paths=()
        mapfile -t target_paths <<<"$processor_out"

        # Copy companion files to the same directory as each primary copy
        local target_path
        for target_path in "${target_paths[@]}"; do
            [[ -n $target_path ]] || continue
            gather_companions "$file" "$(dirname "$target_path")" "$type"
            manifest_add "$target_path" "$type"
        done
    done < <(find build-artifacts -name "$pattern" -print0)
}

# --- Upload dispatch ---

# Default upload loop for simple types (deb, rpm).
# Complex types (jar, nupkg, win, generic) provide their own upload function override.
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

    # shellcheck disable=SC2329  # invoked indirectly via manifest_for_type
    _upload_single_file() {
        local file="$1"
        [[ -f $file ]] || return 0

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

        run jf_upload "$file" "$repo" "${extra_flags[@]}"
        upload_companions "$file" "$repo" "$type"
    }

    manifest_for_type "$type" _upload_single_file
}
