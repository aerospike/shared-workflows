#!/usr/bin/env bash
# type_detection.sh - Content-based artifact type detection during structuring
#
# Required sourcing order (see detect_types.sh): package_utils.sh first, then type_registry.sh,
# upload_utils.sh, then this file. package_utils provides _extract_npm_package_json for is_npm_package.
#
# Required globals / helpers:
#   CONTENT_DETECT_EXTENSIONS, CONTENT_DETECT_ORDER, TYPE_CONTENT_DETECT, TYPE_STRUCT_DIR
#   gather_companions, manifest_add, process_* from package_utils.sh / upload_utils.sh
#
# structure_content_detected_files only reads BUILD_ARTIFACTS_DIR and the registry/helpers above
# (no JFrog globals). Optional: BUILD_ARTIFACTS_DIR (default build-artifacts) — must match
# copy_to_structured() in package_utils.sh
#
# PyPI ambiguous archives use the artifact-publisher style detector (wheel METADATA + sdist
# PKG-INFO / .dist-info METADATA with non-empty Name/Version). Additional passes mirror
# jfrog-fetch "Detect *" steps: wheels under the artifacts root, Maven POM coordinate checks,
# and docker-images.json bundle metadata into generic/docker/.
#
# Content predicates (is_npm_package, is_pypi_package, is_go_module, is_maven_package) live here;
# package_utils keeps metadata extractors (e.g. _extract_npm_package_json, get_go_metadata).

# --- npm --------------------------------------------------------------------------------------

# Check if a .tgz/.tar.gz is an npm package (package.json with name and version).
# Uses _extract_npm_package_json from package_utils.sh.
is_npm_package() {
    local file="$1"
    _extract_npm_package_json "$file" |
        jq -e '.name and .version' >/dev/null 2>&1
}

# --- Go ---------------------------------------------------------------------------------------

# Check if a .zip file is a Go module archive.
# Go module zips have files prefixed with module@version/ and contain go.mod.
# Args: <zip_file>
# Returns: 0 if Go module, 1 otherwise.
is_go_module() {
    local file="$1"
    local listing
    listing=$(unzip -Z1 "$file" 2>/dev/null) || return 1
    echo "$listing" | grep -qE '^[^@]+@v[^/]+/go\.mod$'
}

# --- PyPI (artifact-publisher / artifact-identification.sh style) -----------------------------

_require_nonempty_name_version() {
    local metadata="$1"
    local name version
    name=$(awk -F': *' 'tolower($1)=="name" {print $2; exit}' <<<"$metadata")
    version=$(awk -F': *' 'tolower($1)=="version" {print $2; exit}' <<<"$metadata")
    [[ -n $name && -n $version ]]
}

_identify_python_wheel() {
    local file="$1"
    [[ -n $file && -f $file && -r $file ]] || return 1

    local metadata_member
    metadata_member=$(unzip -Z1 "$file" 2>/dev/null | awk '/\.dist-info\/METADATA$/ {print; exit}') || return 1
    if [[ -z $metadata_member ]]; then
        echo "Not a Python wheel: $file (missing .dist-info/METADATA)" >&2
        return 1
    fi

    local metadata
    metadata=$(unzip -p "$file" "$metadata_member" 2>/dev/null) || return 1
    if ! _require_nonempty_name_version "$metadata"; then
        echo "Not a Python wheel: $file (METADATA missing Name/Version)" >&2
        return 1
    fi
    return 0
}

_identify_python_sdist() {
    local file="$1"
    [[ -n $file && -f $file && -r $file ]] || return 1

    local listing
    listing=$(tar -tzf "$file" 2>/dev/null) || return 1

    local metadata_member
    metadata_member=$(awk '/(^|\/)\.dist-info\/METADATA\r?$/ {print; exit}' <<<"$listing")
    if [[ -n $metadata_member ]]; then
        local metadata
        metadata=$(tar -xzf "$file" -O "$metadata_member" 2>/dev/null) || return 1
        if _require_nonempty_name_version "$metadata"; then
            return 0
        fi
    fi

    local pkg_info_member
    pkg_info_member=$(awk '/(^|\/)PKG-INFO\r?$/ {print; exit}' <<<"$listing")
    if [[ -n $pkg_info_member ]]; then
        local pkg_info
        pkg_info=$(tar -xzf "$file" -O "$pkg_info_member" 2>/dev/null) || return 1
        if _require_nonempty_name_version "$pkg_info"; then
            return 0
        fi
    fi

    echo "Not a Python source dist: $file (PKG-INFO/METADATA missing Name/Version)" >&2
    return 1
}

# is_pypi_package <path>
# Returns 0 if the file is a Python package acceptable for PyPI publish (*.whl or *.tar.gz)
# with non-empty Name/Version in metadata (artifact-publisher approach; replaces PKG-INFO-only sdist sniff).
is_pypi_package() {
    local file="$1"
    case "${file,,}" in
    *.whl) _identify_python_wheel "$file" ;;
    *.tar.gz | *.tgz) _identify_python_sdist "$file" ;;
    *)
        echo "Not a PyPI package: $file (expected *.whl or *.tar.gz / *.tgz)" >&2
        return 1
        ;;
    esac
}

# is_maven_package <path>
# Returns 0 if the POM has resolvable coordinates (artifactId, groupId, version; parent fallbacks).
# Uses xmllint (same stack as deploy entrypoint) instead of yq.
is_maven_package() {
    local file="$1"
    [[ -n $file && -f $file && -r $file ]] || return 1
    case "${file,,}" in
    *.pom) ;;
    *)
        echo "Not a Maven POM: $file (expected *.pom)" >&2
        return 1
        ;;
    esac

    local artifact_id group_id version
    artifact_id=$(xmllint --xpath "string(//*[local-name()='project']/*[local-name()='artifactId'])" "$file" 2>/dev/null || true)
    group_id=$(xmllint --xpath "string(//*[local-name()='project']/*[local-name()='groupId'])" "$file" 2>/dev/null || true)
    if [[ -z $group_id ]]; then
        group_id=$(xmllint --xpath "string(//*[local-name()='project']/*[local-name()='parent']/*[local-name()='groupId'])" "$file" 2>/dev/null || true)
    fi
    version=$(xmllint --xpath "string(//*[local-name()='project']/*[local-name()='version'])" "$file" 2>/dev/null || true)
    if [[ -z $version ]]; then
        version=$(xmllint --xpath "string(//*[local-name()='project']/*[local-name()='parent']/*[local-name()='version'])" "$file" 2>/dev/null || true)
    fi

    if [[ -n $artifact_id && -n $group_id && -n $version ]]; then
        return 0
    fi
    echo "Not a Maven POM: $file (missing coordinates)" >&2
    return 1
}

# Detect npm: handled by existing CONTENT_DETECT_ORDER + is_npm_package (no extra pass).

# Detect PyPI wheels: jfrog-fetch stages *.whl with is_pypi_package; the main content loop only
# scans ambiguous extensions, so wheels are picked up here when structuring runs standalone.
_detect_structure_pypi_wheels() {
    local artifacts_root="$1"
    local dest="./structured_build_artifacts/${TYPE_STRUCT_DIR[pypi]}"
    while IFS= read -r -d '' file; do
        [[ -f $file ]] || continue
        if is_pypi_package "$file"; then
            echo "Processing PYPI (wheel): $file" >&2
            local target_path
            target_path=$(process_pypi "$file" "$dest")
            if [[ -n $target_path ]]; then
                gather_companions "$file" "$(dirname "$target_path")" "pypi"
                manifest_add "$target_path" "pypi"
            fi
        fi
    done < <(find "$artifacts_root" -name "*.whl" -type f -print0 2>/dev/null)
}

# Detect Maven POMs: coordinate validation then same jar/ layout as structure_standalone_poms.
_detect_structure_maven_poms() {
    local artifacts_root="$1"
    while IFS= read -r -d '' pom; do
        [[ -f $pom ]] || continue
        local base_name jar_file
        base_name=$(basename "$pom" .pom)
        jar_file="$(dirname "$pom")/$base_name.jar"
        [[ -f $jar_file ]] && continue

        is_maven_package "$pom" || continue

        echo "Processing MAVEN (standalone POM): $pom" >&2
        local group_id artifact_id version group_path target
        group_id=$(xmllint --xpath "string(//*[local-name()='project']/*[local-name()='groupId'])" "$pom" 2>/dev/null || true)
        artifact_id=$(xmllint --xpath "string(//*[local-name()='project']/*[local-name()='artifactId'])" "$pom" 2>/dev/null || true)
        version=$(xmllint --xpath "string(//*[local-name()='project']/*[local-name()='version'])" "$pom" 2>/dev/null || true)
        if [[ -z $group_id ]]; then
            group_id=$(xmllint --xpath "string(//*[local-name()='project']/*[local-name()='parent']/*[local-name()='groupId'])" "$pom" 2>/dev/null || true)
        fi
        if [[ -z $version ]]; then
            version=$(xmllint --xpath "string(//*[local-name()='project']/*[local-name()='parent']/*[local-name()='version'])" "$pom" 2>/dev/null || true)
        fi
        group_path="${group_id//./\/}"
        target="./structured_build_artifacts/jar/${group_path}/${artifact_id}/${version}"
        mkdir -p "$target"
        cp -a "$pom" "$target/"
        manifest_add "$target/$(basename "$pom")" "jar"
        if [[ -f "${pom}.asc" ]]; then
            cp -a "${pom}.asc" "$target/"
        fi
    done < <(find "$artifacts_root" -name "*.pom" -type f -print0 2>/dev/null)
}

# Detect Docker: jfrog-fetch writes docker-images.json from the Lifecycle API; stage copies for downstream.
_detect_structure_docker_bundle_metadata() {
    local artifacts_root="$1"
    local dest="./structured_build_artifacts/generic/docker"
    while IFS= read -r -d '' file; do
        [[ -f $file ]] || continue
        echo "Processing DOCKER (bundle metadata): $file" >&2
        mkdir -p "$dest"
        cp -a "$file" "$dest/"
        manifest_add "$dest/$(basename "$file")" "generic"
    done < <(find "$artifacts_root" -name "docker-images.json" -type f -print0 2>/dev/null)
}

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

    _detect_structure_pypi_wheels "$artifacts_root"
    _detect_structure_maven_poms "$artifacts_root"
    _detect_structure_docker_bundle_metadata "$artifacts_root"
}
