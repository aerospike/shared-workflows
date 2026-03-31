#!/usr/bin/env bash
set -euo pipefail
export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
trap 'handle_error ${LINENO}' ERR
# shellcheck disable=SC2317
handle_error() {
    local exit_code=$?
    local line_number=$1
    echo "Error: Command failed with exit code $exit_code at line $line_number" >&2
    exit 1
}
error() {
    local reason="${1-}"
    if [[ -n $reason ]]; then
        echo "Error: $reason" >&2
    else
        echo "Error" >&2
    fi
    exit 1
}

# Default values
DRY_RUN="false"
# shellcheck disable=SC2034  # Used by type_registry.sh get_base_props()
BUILD_TYPE=""
# shellcheck disable=SC2034  # Used by type_registry.sh get_base_props()
INTERNAL="false"
METADATA_BUILD_NUMBER=""
# print full command line
echo "Command line: $0 $*" >&2
# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
    --dry-run)
        DRY_RUN="true"
        shift
        ;;
    --jar-group-id)
        JAR_GROUP_ID="$2"
        shift 2
        ;;
    --build-type)
        # shellcheck disable=SC2034
        BUILD_TYPE="$2"
        shift 2
        ;;
    --internal)
        # shellcheck disable=SC2034
        INTERNAL="true"
        shift
        ;;
    --help | -h)
        echo "Usage: $0 <project> <build-name> <version> <build-number> [metadata-build-number] [OPTIONS]" >&2
        echo "" >&2
        echo "Uploads artifacts to JFrog Artifactory" >&2
        echo "" >&2
        echo "Arguments:" >&2
        echo "  metadata-build-number  (optional) Build ID prefix used to discover child build-infos for aggregation (searches for <prefix>*.json)" >&2
        echo "" >&2
        echo "Options:" >&2
        echo "  --jar-group-id <group-id>        Maven group ID for JAR artifacts" >&2
        echo "  --build-type <label>             Freeform build type label (e.g., release, nightly)" >&2
        echo "  --internal                       Mark artifacts as internal-only (not for public promotion)" >&2
        echo "  --dry-run        Show what would be uploaded without actually uploading" >&2
        echo "  --help, -h       Show this help message" >&2
        echo "" >&2
        echo "Examples:" >&2
        echo "  $0  database my-app v1.0.0 1754566442238 1754566442238-metadata" >&2
        echo "  $0  database my-app v1.0.0 1754566442238 1754566442238-metadata --dry-run" >&2
        echo "  $0  database my-app v1.0.0 1754566442238 1754566442238-metadata --jar-group-id com.aerospike.test" >&2
        exit 0
        ;;
    -*)
        echo "Unknown option: $1" >&2
        echo "Use --help for usage information" >&2
        exit 1
        ;;
    *)
        # Positional arguments
        if [[ -z ${PROJECT-} ]]; then
            PROJECT="$1"
        elif [[ -z ${BUILD_NAME-} ]]; then
            BUILD_NAME="$1"
        elif [[ -z ${VERSION-} ]]; then
            VERSION="$1"
        elif [[ -z ${BUILD_NUMBER-} ]]; then
            BUILD_NUMBER="$1"
        elif [[ -z ${METADATA_BUILD_NUMBER-} ]]; then
            METADATA_BUILD_NUMBER="$1"
        else
            echo "Use --help for usage information" >&2
            exit 1
        fi
        shift
        ;;
    esac
done

if [[ -z ${PROJECT-} ]]; then
    error "project is required
Use --help for usage information"
fi

if [[ -z ${BUILD_NAME-} ]]; then
    error "build-name is required
Use --help for usage information"
fi

if [[ -z ${VERSION-} ]]; then
    error "version is required
Use --help for usage information"
fi

if [[ -z ${BUILD_NUMBER-} ]]; then
    error "build-number is required
Use --help for usage information"
fi

ARTIFACT_BUILD_NUMBER="$BUILD_NUMBER-artifacts"

# Source utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/package_utils.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/type_registry.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/upload_utils.sh"

# Wrapper function that either executes or echoes commands
run() {
    if [[ $DRY_RUN == "true" ]]; then
        # Define color variables
        local green='\033[0;32m'
        local reset='\033[0m'

        echo -e "${green}   $*${reset}" >&2
    else
        "$@"
    fi
}

run_optional() {
    run "$@" || echo "Warning: $*" >&2
}

structure_build_artifacts() {
    echo "Structuring build artifacts..." >&2

    # Create all type directories from registry
    for dir in "${TYPE_STRUCT_DIR[@]}"; do
        mkdir -p "structured_build_artifacts/$dir"
    done

    for type in "${!TYPE_EXTENSIONS[@]}"; do
        # npm requires content-based detection (handled separately below)
        [[ $type == "npm" ]] && continue
        local dest="./structured_build_artifacts/${TYPE_STRUCT_DIR[$type]}"
        local label="${type^^}"
        local processor="process_${type}"
        # snupkg uses process_nupkg
        [[ $type == "snupkg" ]] && processor="process_nupkg"
        discover_and_process "${TYPE_EXTENSIONS[$type]}" "$label" "$processor" "$dest" "$type"
    done

    # npm: content-based detection for .tgz files
    # .tgz is ambiguous (npm pack vs generic tarball), so we inspect each file.
    # npm packages always contain package/package.json.
    # Non-npm .tgz files are routed to generic instead.
    while IFS= read -r -d '' file; do
        [[ -f $file ]] || continue
        if is_npm_package "$file"; then
            echo "Processing NPM: $file" >&2
            local target_path
            target_path=$(process_npm "$file" "./structured_build_artifacts/npm")
            if [[ -n $target_path ]]; then
                gather_companions "$file" "$(dirname "$target_path")" "npm"
            fi
        else
            echo "Processing generic file (non-npm .tgz): $file" >&2
            local target_path
            target_path=$(process_generic "$file" "./structured_build_artifacts/generic")
            if [[ -n $target_path ]]; then
                gather_companions "$file" "$(dirname "$target_path")" "generic"
            fi
        fi
    done < <(find build-artifacts -name "*.tgz" -print0)

    # pypi sdist: content-based detection for .tar.gz files
    # .tar.gz is ambiguous (Python sdist vs generic tarball), so we inspect each file.
    # Python sdists always contain {name}-{version}/PKG-INFO at the root.
    # Non-sdist .tar.gz files are routed to generic instead.
    while IFS= read -r -d '' file; do
        [[ -f $file ]] || continue
        if is_pypi_sdist "$file"; then
            echo "Processing PYPI sdist: $file" >&2
            local target_path
            target_path=$(process_pypi "$file" "./structured_build_artifacts/pypi")
            if [[ -n $target_path ]]; then
                gather_companions "$file" "$(dirname "$target_path")" "pypi"
            fi
        else
            echo "Processing generic file (non-sdist .tar.gz): $file" >&2
            local target_path
            target_path=$(process_generic "$file" "./structured_build_artifacts/generic")
            if [[ -n $target_path ]]; then
                gather_companions "$file" "$(dirname "$target_path")" "generic"
            fi
        fi
    done < <(find build-artifacts -name "*.tar.gz" -print0)

    # Standalone POM files (unique logic: check for corresponding JAR, inline metadata)
    while IFS= read -r -d '' pom; do
        [[ -f $pom ]] || continue
        base_name=$(basename "$pom" .pom)
        jar_file="$(dirname "$pom")/$base_name.jar"

        # Skip if a corresponding JAR exists (already handled by process_jar)
        [[ -f $jar_file ]] && continue

        echo "Processing standalone POM: $pom" >&2

        # Extract metadata from POM
        group_id=$(xmllint --xpath "string(//*[local-name()='project']/*[local-name()='groupId'])" "$pom" 2>/dev/null)
        artifact_id=$(xmllint --xpath "string(//*[local-name()='project']/*[local-name()='artifactId'])" "$pom" 2>/dev/null)
        version=$(xmllint --xpath "string(//*[local-name()='project']/*[local-name()='version'])" "$pom" 2>/dev/null)

        group_path="${group_id//./\/}"

        target="./structured_build_artifacts/jar/${group_path}/${artifact_id}/${version}"
        mkdir -p "$target"
        cp "$pom" "$target/"
        if [[ -f "$pom.asc" ]]; then
            cp "$pom.asc" "$target/"
        fi
    done < <(find build-artifacts -name "*.pom" -print0)

    # Generic: everything not claimed by a registered type
    local -a exclude_args=()
    while IFS= read -r ext; do
        exclude_args+=(-not -name "$ext")
    done < <(get_known_extensions)

    while IFS= read -r -d '' generic; do
        if [[ ! -f $generic ]]; then
            echo "Skipping non-file: $generic" >&2
            continue
        fi
        echo "Processing generic file: $generic" >&2
        local target_path
        target_path=$(process_generic "$generic" "./structured_build_artifacts/generic")

        if [[ -n $target_path ]]; then
            gather_companions "$generic" "$(dirname "$target_path")" "generic"
        fi
    done < <(find build-artifacts \( "${exclude_args[@]}" \) -type f -print0)
}

# DEB and RPM uploads are handled by upload_type() via the type registry.
# No custom upload_deb_packages or upload_rpm_packages needed.

upload_jar_packages() {
    echo "Uploading JAR/POM files to JFrog..." >&2

    # Find all JAR and POM files, then process unique base names
    declare -A processed_artifacts

    while IFS= read -r -d '' artifact; do
        [[ -f $artifact ]] || continue

        # Get the directory and base name
        local artifact_dir artifact_name base_name
        artifact_dir=$(dirname "$artifact")
        artifact_name=$(basename "$artifact")
        base_name="${artifact_name%.jar}"
        base_name="${base_name%.pom}"

        # Skip if we've already processed this base artifact
        local artifact_key="$artifact_dir/$base_name"
        if [[ -n ${processed_artifacts[$artifact_key]-} ]]; then
            continue
        fi
        processed_artifacts[$artifact_key]=1

        local pkgname version group_id
        local jar_file="$artifact_dir/${base_name}.jar"
        local pom_file="$artifact_dir/${base_name}.pom"

        if [[ -f $jar_file ]]; then
            local -a metadata
            read -r -a metadata < <(get_jar_metadata "$jar_file")
            pkgname="${metadata[0]}"
            version="${metadata[1]}"
            group_id="${metadata[2]-${JAR_GROUP_ID-}}"
        elif [[ -f $pom_file ]]; then
            pkgname=$(xmllint --xpath "string(//*[local-name()='project']/*[local-name()='artifactId'])" "$pom_file" 2>/dev/null)
            version=$(xmllint --xpath "string(//*[local-name()='project']/*[local-name()='version'])" "$pom_file" 2>/dev/null)
            group_id=$(xmllint --xpath "string(//*[local-name()='project']/*[local-name()='groupId'])" "$pom_file" 2>/dev/null)
        fi

        [[ -z ${group_id-} ]] && group_id="${JAR_GROUP_ID-}"

        # If no group_id is available, move to generic directory for generic upload
        if [[ -z ${group_id-} ]]; then
            echo "  Moving JAR without group_id to generic directory: $artifact" >&2
            for ext in jar pom jar.asc pom.asc; do
                local artifact_file="$artifact_dir/${base_name}.${ext}"
                if [[ -f $artifact_file ]]; then
                    mv "$artifact_file" "../generic/"
                fi
            done
            continue
        fi

        echo "  Package: $pkgname, Version: $version, Group ID: $group_id" >&2
        local props
        props=$(get_jar_props "$artifact" "$group_id" "$pkgname")

        # Upload all related Maven artifact files (jar, pom, signatures)
        for ext in jar pom jar.asc pom.asc; do
            local artifact_file="$artifact_dir/${base_name}.${ext}"
            if [[ -f $artifact_file ]]; then
                echo "  Uploading $ext: $artifact_file" >&2
                jf_upload "$artifact_file" "$PROJECT-maven-dev-local" \
                    --target-props "$props"
            fi
        done
    done < <(find . \( -name "*.jar" -o -name "*.pom" \) -print0)
}

upload_nupkg_packages() {
    echo "Uploading NuGet packages to JFrog..." >&2

    # loop for both .nupkg and .snupkg
    while IFS= read -r -d '' pkg; do
        [[ -f $pkg ]] || continue

        local -a metadata
        read -r -a metadata < <(get_nupkg_metadata "$pkg")
        local pkgname="${metadata[0]}"
        local pkgversion="${metadata[1]}"
        local pkg_filename
        pkg_filename=$(basename "$pkg")

        if [[ -z $pkgname ]] || [[ -z $pkgversion ]]; then
            echo "Warning: Failed to extract metadata from $pkg, using filename-based path" >&2
            pkgname="${pkg_filename%.nupkg}"
            pkgname="${pkgname%.snupkg}"
            pkgversion="unknown"
        fi

        local props
        props=$(get_nupkg_props "$pkg")

        echo "  Uploading NuGet package: $pkg" >&2
        echo "    Package: $pkgname, Version: $pkgversion" >&2
        # NuGet uses custom target path (not --flat=false), so we call run directly
        run jf rt upload "$pkg" "$PROJECT-nuget-dev-local/${pkgname}/${pkgversion}/${pkg_filename}" \
            --build-name="$BUILD_NAME" \
            --build-number="$ARTIFACT_BUILD_NUMBER" \
            --project="$PROJECT" \
            --target-props "$props"

        # Upload companion files (.asc signatures)
        # Determine type from extension for companion lookup
        local pkg_type="nupkg"
        [[ $pkg == *.snupkg ]] && pkg_type="snupkg"
        upload_companions "$pkg" "$PROJECT-nuget-dev-local" "$pkg_type"
    done < <(find . \( -name "*.nupkg" -o -name "*.snupkg" \) -print0)
}

upload_npm_packages() {
    echo "Uploading npm packages to JFrog..." >&2

    while IFS= read -r -d '' pkg; do
        [[ -f $pkg ]] || continue

        local -a metadata
        read -r -a metadata < <(get_npm_metadata "$pkg")
        local pkgname="${metadata[0]}"
        local pkgversion="${metadata[1]}"
        local pkg_filename
        pkg_filename=$(basename "$pkg")

        if [[ -z $pkgname ]] || [[ -z $pkgversion ]]; then
            echo "Warning: Failed to extract metadata from $pkg, skipping" >&2
            continue
        fi

        local props
        props=$(get_npm_props "$pkg")

        # JFrog npm layout: @scope/name/-/filename.tgz (scoped) or name/-/filename.tgz (unscoped)
        local target_path
        target_path="${pkgname}/-/${pkg_filename}"

        echo "  Uploading npm package: $pkg" >&2
        echo "    Package: $pkgname, Version: $pkgversion" >&2
        echo "    Target: $target_path" >&2
        run jf rt upload "$pkg" "$PROJECT-npm-dev-local/${target_path}" \
            --build-name="$BUILD_NAME" \
            --build-number="$ARTIFACT_BUILD_NUMBER" \
            --project="$PROJECT" \
            --target-props "$props"

        # Upload companions with explicit target path (same directory as the package)
        local companions="${TYPE_COMPANIONS[npm]-}"
        for suffix in $companions; do
            if [[ -f "$pkg$suffix" ]]; then
                echo "  Uploading companion: $pkg$suffix" >&2
                run jf rt upload "$pkg$suffix" "$PROJECT-npm-dev-local/${target_path}${suffix}" \
                    --build-name="$BUILD_NAME" \
                    --build-number="$ARTIFACT_BUILD_NUMBER" \
                    --project="$PROJECT"
            fi
        done
    done < <(find . -name "*.tgz" -print0)
}

upload_pypi_packages() {
    echo "Uploading PyPI packages to JFrog..." >&2

    while IFS= read -r -d '' pkg; do
        [[ -f $pkg ]] || continue

        local -a metadata
        read -r -a metadata < <(get_pypi_metadata "$pkg")
        local pkgname="${metadata[0]}"
        local pkgversion="${metadata[1]}"
        local pkg_filename
        pkg_filename=$(basename "$pkg")

        if [[ -z $pkgname ]] || [[ -z $pkgversion ]]; then
            echo "Warning: Failed to extract metadata from $pkg, skipping" >&2
            continue
        fi

        local normalized_name
        normalized_name=$(_normalize_pypi_name "$pkgname")

        local props
        props=$(get_pypi_props "$pkg")

        # JFrog PyPI layout: {normalized-name}/{version}/{filename}
        local target_path
        target_path="${normalized_name}/${pkgversion}/${pkg_filename}"

        echo "  Uploading PyPI package: $pkg" >&2
        echo "    Package: $pkgname (normalized: $normalized_name), Version: $pkgversion" >&2
        echo "    Target: $target_path" >&2
        run jf rt upload "$pkg" "$PROJECT-pypi-dev-local/${target_path}" \
            --build-name="$BUILD_NAME" \
            --build-number="$ARTIFACT_BUILD_NUMBER" \
            --project="$PROJECT" \
            --target-props "$props"

        # Upload companions with explicit target path (same directory as the package)
        local companions="${TYPE_COMPANIONS[pypi]-}"
        for suffix in $companions; do
            if [[ -f "$pkg$suffix" ]]; then
                echo "  Uploading companion: $pkg$suffix" >&2
                run jf rt upload "$pkg$suffix" "$PROJECT-pypi-dev-local/${target_path}${suffix}" \
                    --build-name="$BUILD_NAME" \
                    --build-number="$ARTIFACT_BUILD_NUMBER" \
                    --project="$PROJECT"
            fi
        done
    done < <(find . \( -name "*.whl" -o -name "*.tar.gz" \) -print0)
}

upload_generic_files() {
    echo "Uploading generic files..." >&2

    # Only exclude companion/build file extensions.
    local -a exclude_args=(-not -name "*.asc" -not -name "*.pom" -not -name "*.csproj")

    while IFS= read -r -d '' file; do
        [[ -f $file ]] || continue
        echo "Uploading generic file: $file" >&2

        local props
        props=$(get_generic_props "$file")

        jf_upload "$file" "$PROJECT-generic-dev-local" \
            --target-props "$props"

        upload_companions "$file" "$PROJECT-generic-dev-local" "generic"
    done < <(find . \( "${exclude_args[@]}" \) -type f -print0)
}

# Collects build-info metadata by querying Artifactory for JSON files.
# JFrog API doesn't support wildcarding build IDs, so we fetch the JSON
# files to extract the collection of build IDs for this parent build.
discover_build_infos() {
    local project="$1"
    local parent_build_name="$2"
    local build_info_search_pattern="$3"
    local build_info_repo="${4:-${project}-build-info}"

    echo "Discovering build-infos for project: $project" >&2
    echo "Parent build name: $parent_build_name" >&2
    echo "Search pattern: $build_info_search_pattern" >&2
    echo "Build-info repo: $build_info_repo" >&2

    read -r -d '' AQL <<AQL || true
items.find({
  "\$and":[
    {"repo":{"\$eq":"$build_info_repo"}},
    {"path":{"\$eq":"$parent_build_name"}},
    {"name":{"\$match":"$build_info_search_pattern.json"}},
    {"created":{"\$last":"1d"}}
  ]
}).include("repo","path","name")
AQL
    echo run jf rt curl -XPOST api/search/aql \
        -H 'Content-Type: text/plain' \
        -d "$AQL" >&2
    # Query for build-info JSON files
    local resp
    resp=$(run jf rt curl -XPOST api/search/aql \
        -H 'Content-Type: text/plain' \
        -d "$AQL")
    echo "search response: $resp" >&2
    # Extract child build IDs from JSON file names
    if echo "$resp" | jq -e '.results' >/dev/null 2>&1; then
        mapfile -t CHILD_BUILD_IDS < <(echo "$resp" | jq -r '.results[] | .name' | sed 's/-[0-9]*\.json$//' | sort -u)

        echo "Found ${#CHILD_BUILD_IDS[@]} child builds" >&2

        CHILD_BUILD_IDS_RESULT=("${CHILD_BUILD_IDS[@]}")
        return 0
    else
        echo "No build-info files found" >&2
        CHILD_BUILD_IDS_RESULT=()
        return 1
    fi
}

# This function handles publishing the tree of build info to jfrog
# 1. publish the signed artifacts
# 2. append metadata and artifact build infos to new build info
# 3. publish the new build info
publish_build_info() {
    run jf rt build-publish "$BUILD_NAME" "$ARTIFACT_BUILD_NUMBER" --project="$PROJECT"

    if [[ -n $METADATA_BUILD_NUMBER ]]; then
        discover_build_infos "$PROJECT" "$BUILD_NAME" "$METADATA_BUILD_NUMBER*" "$PROJECT-build-info" || true

        if [[ ${#CHILD_BUILD_IDS_RESULT[@]} -gt 0 ]]; then
            echo "Found ${#CHILD_BUILD_IDS_RESULT[@]} child builds:" >&2
            for build_id in "${CHILD_BUILD_IDS_RESULT[@]}"; do
                echo "  $BUILD_NAME/$build_id"
                run jf rt build-append "$BUILD_NAME" "$BUILD_NUMBER" \
                    "$BUILD_NAME" "$build_id" --project="$PROJECT"
            done
        fi
    fi

    run jf rt build-append "$BUILD_NAME" "$BUILD_NUMBER" \
        "$BUILD_NAME" "$ARTIFACT_BUILD_NUMBER" --project="$PROJECT"
    run jf rt build-publish "$BUILD_NAME" "$BUILD_NUMBER" --project="$PROJECT"
}

main() {
    if [[ $DRY_RUN == "true" ]]; then
        echo "Would deploy artifacts to JFrog Artifactory" >&2
    else
        echo "Deploying artifacts to JFrog Artifactory" >&2
    fi
    echo "Project: $PROJECT" >&2
    echo "Build name: $BUILD_NAME" >&2
    echo "Version: $VERSION" >&2
    echo "Dry run: $DRY_RUN" >&2
    echo "Build number: $BUILD_NUMBER" >&2
    echo "Metadata build number: $METADATA_BUILD_NUMBER" >&2

    if [[ ! -d build-artifacts ]]; then
        error "build-artifacts directory does not exist. Artifacts must be downloaded before running this script."
    fi

    mkdir -p structured_build_artifacts
    shopt -s globstar nullglob

    structure_build_artifacts
    cd structured_build_artifacts

    # Upload all types in the order defined by the registry (e.g., deb before rpm, so debian upload commands run before rpm).
    for type in "${UPLOAD_ORDER[@]}"; do
        local dir="${TYPE_STRUCT_DIR[$type]:-$type}"
        (cd "$dir" && upload_type "$type")
    done

    # Publish build info once for the unified build
    publish_build_info

    echo "Deploy complete!" >&2
    echo "Build name: $BUILD_NAME" >&2
    echo "Build number: $BUILD_NUMBER" >&2
}

main "$@"
