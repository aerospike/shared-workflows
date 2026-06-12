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
# jfrog-fetch-style passes: wheels, Maven POMs, docker-images.json, NuGet packages
# (.nupkg / .snupkg by extension, validated with is_nuget_package from artifact-publisher).
#
# Content predicates (is_npm_package, is_pypi_package, is_go_module, is_maven_package,
# is_nuget_package, is_helm_chart) live here; package_utils keeps metadata extractors.

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

# --- Helm -------------------------------------------------------------------------------------
# is_helm_chart and _extract_helm_chart_yaml live in ../lib/helm-helpers.sh and
# are sourced by entrypoint.sh + detect_types.sh. Same file is sourced by
# sign-artifacts/entrypoint.sh so detection stays consistent across stages.

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

# --- NuGet (artifact-publisher artifact-identification.sh) ------------------------------------

_nuget_trim() {
    local s="$1"
    s="${s//$'\r'/}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# is_nuget_package <path>
# Returns 0 if the file is a *.nupkg or *.snupkg zip containing a .nuspec with non-empty <id> and <version>.
is_nuget_package() {
    local f="$1"
    local nuspec xml pkg_id version raw_id raw_version

    [[ -n $f && -f $f && -r $f ]] || return 1
    case "${f,,}" in
    *.nupkg | *.snupkg) ;;
    *)
        echo "Not a NuGet package: $f (expected *.nupkg or *.snupkg)" >&2
        return 1
        ;;
    esac

    if ! command -v unzip >/dev/null 2>&1; then
        echo "Not a NuGet package: unzip is required" >&2
        return 1
    fi

    nuspec=$(unzip -Z1 "$f" 2>/dev/null | grep -E '\.nuspec$' | head -n1) || return 1
    [[ -n $nuspec ]] || return 1

    xml=$(unzip -p "$f" "$nuspec" 2>/dev/null) || return 1
    [[ -n $xml ]] || return 1

    raw_id=$(printf '%s' "$xml" | sed -n 's/.*<id>\([^<]*\)<\/id>.*/\1/p' | head -n1)
    raw_version=$(printf '%s' "$xml" | sed -n 's/.*<version>\([^<]*\)<\/version>.*/\1/p' | head -n1)
    pkg_id=$(_nuget_trim "$raw_id")
    version=$(_nuget_trim "$raw_version")

    if [[ -n $pkg_id && -n $version ]]; then
        return 0
    fi
    echo "Not a NuGet package: $f (.nuspec missing id or version)" >&2
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
            else
                echo "Warning: PyPI wheel passed is_pypi_package but process_pypi returned no target path; artifact not copied: $file" >&2
            fi
        fi
    done < <(find "$artifacts_root" -name "*.whl" -type f -print0 2>/dev/null)
}

# Detect NuGet: extension-based find; is_nuget_package validates .nuspec (artifact-publisher).
# Uses TYPE_STRUCT_DIR[nupkg] and process_nupkg for both .nupkg and .snupkg; manifest type matches extension.
_detect_structure_nuget_packages() {
    local artifacts_root="$1"
    local dest="./structured_build_artifacts/${TYPE_STRUCT_DIR[nupkg]}"
    while IFS= read -r -d '' file; do
        [[ -f $file ]] || continue
        is_nuget_package "$file" || continue
        local kind=nupkg
        case "${file,,}" in
        *.snupkg) kind=snupkg ;;
        esac
        echo "Processing ${kind^^}: $file" >&2
        local target_path
        target_path=$(process_nupkg "$file" "$dest")
        if [[ -n $target_path ]]; then
            gather_companions "$file" "$(dirname "$target_path")" "$kind"
            manifest_add "$target_path" "$kind"
        else
            echo "Warning: ${kind^^} passed is_nuget_package but process_nupkg returned no target path; artifact not copied: $file" >&2
        fi
    done < <(find "$artifacts_root" \( -name "*.nupkg" -o -name "*.snupkg" \) -type f -print0 2>/dev/null)
}

# --- Maven bundle metadata (multi-module / flatten-maven-plugin heuristics) --------------------
# Writes structured_build_artifacts/.maven-bundle-metadata.json after scanning all *.pom under
# the artifacts root. See detect-artifacts action output bundle-metadata-path.

# _maven_read_pom_coordinates <pom>
# Sets: _mv_group_id _mv_artifact_id _mv_version _mv_packaging _mv_module_count (int)
_maven_read_pom_coordinates() {
    local pom="$1"
    _mv_artifact_id=$(xmllint --xpath "string(/*[local-name()='project']/*[local-name()='artifactId'])" "$pom" 2>/dev/null || true)
    _mv_group_id=$(xmllint --xpath "string(/*[local-name()='project']/*[local-name()='groupId'])" "$pom" 2>/dev/null || true)
    if [[ -z ${_mv_group_id} ]]; then
        _mv_group_id=$(xmllint --xpath "string(/*[local-name()='project']/*[local-name()='parent']/*[local-name()='groupId'])" "$pom" 2>/dev/null || true)
    fi
    _mv_version=$(xmllint --xpath "string(/*[local-name()='project']/*[local-name()='version'])" "$pom" 2>/dev/null || true)
    if [[ -z ${_mv_version} ]]; then
        _mv_version=$(xmllint --xpath "string(/*[local-name()='project']/*[local-name()='parent']/*[local-name()='version'])" "$pom" 2>/dev/null || true)
    fi
    _mv_packaging=$(xmllint --xpath "string(/*[local-name()='project']/*[local-name()='packaging'])" "$pom" 2>/dev/null || true)
    [[ -z ${_mv_packaging} ]] && _mv_packaging="jar"
    _mv_module_count=$(xmllint --xpath "count(/*[local-name()='project']/*[local-name()='modules']/*[local-name()='module'])" "$pom" 2>/dev/null || echo 0)
    if [[ -z ${_mv_module_count} ]] || [[ ! (${_mv_module_count} =~ ^[0-9]+$) ]]; then
        _mv_module_count=0
    fi
}

# _pom_has_flatten_maven_plugin_marker <pom>
# True when the preamble mentions the plugin (typical when keepCommentsInPom or header comment preserved).
_pom_has_flatten_maven_plugin_marker() {
    local pom="$1"
    head -c 24576 "$pom" 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -q 'flatten-maven-plugin'
}

# _pom_matches_flatten_resolved_heuristic <pom>
# Structural hint aligned with https://www.mojohaus.org/flatten-maven-plugin/flatten-mojo.html :
# consumer flattened POMs usually have no parent, no modules, no ${...} interpolation, and publish
# resolved direct dependencies. We skip packaging=pom (BOM/aggregator) to avoid false positives on
# minimal parent-only POMs. Marker comment (_pom_has_flatten_maven_plugin_marker) remains the
# strongest signal for flattened BOMs.
_pom_matches_flatten_resolved_heuristic() {
    local pom="$1"
    is_maven_package "$pom" || return 1
    _maven_read_pom_coordinates "$pom"
    if [[ ${_mv_packaging,,} == pom ]]; then
        return 1
    fi
    local dep_count
    dep_count=$(xmllint --xpath "count(/*[local-name()='project']/*[local-name()='dependencies']/*[local-name()='dependency'])" "$pom" 2>/dev/null || echo 0)
    [[ $dep_count =~ ^[0-9]+$ ]] || dep_count=0
    [[ $dep_count -gt 0 ]] || return 1
    if grep -qE '\$\{' "$pom" 2>/dev/null; then
        return 1
    fi
    local pc mc
    pc=$(xmllint --xpath "count(/*[local-name()='project']/*[local-name()='parent'])" "$pom" 2>/dev/null || echo 1)
    [[ $pc =~ ^[0-9]+$ ]] || pc=1
    [[ $pc -eq 0 ]] || return 1
    mc=$(xmllint --xpath "count(/*[local-name()='project']/*[local-name()='modules']/*[local-name()='module'])" "$pom" 2>/dev/null || echo 1)
    [[ $mc =~ ^[0-9]+$ ]] || mc=1
    [[ $mc -eq 0 ]] || return 1
    return 0
}

# _pom_is_flattened_maven_style <pom>
_pom_is_flattened_maven_style() {
    local pom="$1"
    _pom_has_flatten_maven_plugin_marker "$pom" && return 0
    _pom_matches_flatten_resolved_heuristic "$pom" && return 0
    return 1
}

# _write_maven_bundle_metadata_json <artifacts_root>
# Emits JSON with is_multi_package, maven_module_count, maven_aggregator_present, is_flattened.
_write_maven_bundle_metadata_json() {
    local artifacts_root="$1"
    local out="./structured_build_artifacts/.maven-bundle-metadata.json"
    declare -A gav_seen=()
    local maven_aggregator_present=false
    local is_flattened=false

    while IFS= read -r -d '' pom; do
        [[ -f $pom ]] || continue
        is_maven_package "$pom" || continue
        _maven_read_pom_coordinates "$pom"
        if [[ -z ${_mv_group_id-} || -z ${_mv_artifact_id-} || -z ${_mv_version-} ]]; then
            echo "Notice: excluding POM from Maven bundle metadata (incomplete GAV after coordinate read): $pom (group_id='${_mv_group_id-}' artifact_id='${_mv_artifact_id-}' version='${_mv_version-}')" >&2
            continue
        fi
        local gav_key="${_mv_group_id}|${_mv_artifact_id}|${_mv_version}"
        gav_seen["$gav_key"]=1

        if [[ ${_mv_packaging,,} == pom && $_mv_module_count -gt 0 ]]; then
            maven_aggregator_present=true
        fi
        if _pom_is_flattened_maven_style "$pom"; then
            is_flattened=true
        fi
    done < <(find "$artifacts_root" -name "*.pom" -type f -print0 2>/dev/null)

    local maven_module_count=${#gav_seen[@]}
    local is_multi_package=false
    [[ $maven_module_count -gt 1 ]] && is_multi_package=true

    if ! command -v jq >/dev/null 2>&1; then
        echo "Error: jq is required to write $out" >&2
        return 1
    fi
    jq -n \
        --argjson is_multi_package "$is_multi_package" \
        --argjson maven_module_count "$maven_module_count" \
        --argjson maven_aggregator_present "$maven_aggregator_present" \
        --argjson is_flattened "$is_flattened" \
        '{is_multi_package: $is_multi_package, maven_module_count: $maven_module_count, maven_aggregator_present: $maven_aggregator_present, is_flattened: $is_flattened}' \
        >"$out"
    echo "Wrote Maven bundle metadata ($maven_module_count unique GAV(s)): $out" >&2
}

# Detect Maven POMs: coordinate validation then same jar/ layout as structure_standalone_poms.
_detect_structure_maven_poms() {
    local artifacts_root="$1"
    while IFS= read -r -d '' pom; do
        [[ -f $pom ]] || continue
        local base_name jar_file
        base_name=$(basename "$pom" .pom)
        jar_file="$(dirname "$pom")/$base_name.jar"
        if [[ ! -f $jar_file ]]; then
            echo "Notice: skipping standalone POM structuring (no sibling JAR): $pom (expected $jar_file)" >&2
            continue
        fi

        if ! is_maven_package "$pom"; then
            echo "Notice: skipping standalone POM structuring (Maven package validation failed): $pom" >&2
            continue
        fi

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
                else
                    echo "Warning: content detection classified as ${type^^} but processor returned no target path; artifact not copied: $file" >&2
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
            else
                echo "Warning: generic fallback after content detection produced no target path; artifact not copied: $file" >&2
            fi
        fi
    done < <(find "$artifacts_root" \( "${find_args[@]}" \) -print0)

    _detect_structure_pypi_wheels "$artifacts_root"
    _detect_structure_nuget_packages "$artifacts_root"
    _detect_structure_maven_poms "$artifacts_root"
    _detect_structure_docker_bundle_metadata "$artifacts_root"
    _write_maven_bundle_metadata_json "$artifacts_root"
}
