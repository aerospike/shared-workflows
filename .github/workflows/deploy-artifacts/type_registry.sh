#!/usr/bin/env bash
# type_registry.sh - Centralized type registry for artifact deployment
#
# To add a new artifact type:
#   1. Call register_type below with the type's properties
#   2. Add a get_TYPE_props() function
#   3. Add a process_TYPE() function in package_utils.sh (or reuse process_generic)
#   4. Add tests
#
# Required globals (set by entrypoint.sh before sourcing):
#   VERSION, BUILD_NAME, PROJECT, BUILD_TYPE, INTERNAL

# --- Registry infrastructure ---
# These arrays are used by upload_utils.sh and entrypoint.sh (sourced, not executed directly)
# shellcheck disable=SC2034

declare -A TYPE_EXTENSIONS=()
declare -A TYPE_REPO=()
declare -A TYPE_COMPANIONS=()
declare -A TYPE_STRUCT_DIR=()
declare -A TYPE_CONTENT_DETECT=()
CONTENT_DETECT_EXTENSIONS=()
CONTENT_DETECT_ORDER=()

register_type() {
    local type="$1"
    shift
    local extension="" repo="" companions=".asc" struct_dir="$type" detect=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
        --extension)
            extension="$2"
            shift 2
            ;;
        --repo)
            repo="$2"
            shift 2
            ;;
        --companions)
            companions="$2"
            shift 2
            ;;
        --struct-dir)
            struct_dir="$2"
            shift 2
            ;;
        --detect)
            detect="$2"
            shift 2
            ;;
        *)
            echo "Unknown register_type option: $1" >&2
            return 1
            ;;
        esac
    done

    [[ -n $extension ]] && TYPE_EXTENSIONS[$type]="$extension"
    TYPE_REPO[$type]="$repo"
    TYPE_COMPANIONS[$type]="$companions"
    TYPE_STRUCT_DIR[$type]="$struct_dir"

    if [[ -n $detect ]]; then
        TYPE_CONTENT_DETECT[$type]="$detect"
        CONTENT_DETECT_ORDER+=("$type")
    fi
}

# --- Type registrations ---
# Each call defines all properties for one artifact type.
# Defaults: --companions ".asc", --struct-dir same as type name.

register_type deb --extension "*.deb" --repo "deb-dev-local"
register_type rpm --extension "*.rpm" --repo "rpm-dev-local"
register_type jar --extension "*.jar" --repo "maven-dev-local" --companions ".pom .asc .pom.asc"
register_type nupkg --extension "*.nupkg" --repo "nuget-dev-local"
register_type snupkg --extension "*.snupkg" --repo "nuget-dev-local" --struct-dir "nupkg"
register_type npm --repo "npm-dev-local" --detect "is_npm_package"
register_type pypi --extension "*.whl" --repo "pypi-dev-local" --detect "is_pypi_sdist"
register_type generic --repo "generic-dev-local"

# Ambiguous extensions that trigger content-based detection.
# Shared across all content-detected types (npm, pypi sdist, etc.).
# Files matching these patterns are tested against detectors in CONTENT_DETECT_ORDER;
# unmatched files route to generic.
CONTENT_DETECT_EXTENSIONS=("*.tgz" "*.tar.gz")

# Upload order matters: jar before generic (jar can move files to generic)
UPLOAD_ORDER=(rpm deb jar nupkg npm pypi generic)

# --- helpers ---

# Returns the list of all known file extensions (primary + content-detected + companion + build).
# Used to build the negated find pattern for generic file discovery.
get_known_extensions() {
    local -a exts=()
    for ext_pattern in "${TYPE_EXTENSIONS[@]}"; do
        exts+=("$ext_pattern")
    done
    # Content-detected extensions (ambiguous types like .tgz/.tar.gz)
    exts+=("${CONTENT_DETECT_EXTENSIONS[@]}")
    # Companion and build file extensions
    exts+=("*.asc" "*.pom" "*.csproj")
    printf '%s\n' "${exts[@]}"
}

# --- Base properties ---

# Base target-props applied to ALL artifact types.
get_base_props() {
    # shellcheck disable=SC2153  # VERSION is set by entrypoint.sh before sourcing
    local props="version=$VERSION"
    [[ -n ${BUILD_TYPE-} ]] && props+=";build.type=$BUILD_TYPE"
    [[ ${INTERNAL-} == "true" ]] && props+=";internal=true"
    echo "$props"
}

# --- Per-type properties ---
# Convention: get_TYPE_props <file> returns a semicolon-delimited props string.
# Convention: get_TYPE_extra_flags <file> returns additional jf rt upload flags.

get_deb_props() {
    local file="$1"
    local pkgname arch codename
    pkgname=$(dpkg-deb -f "$file" Package)
    arch=$(dpkg-deb -f "$file" Architecture)
    if ! codename=$(get_codename_for_deb "$file"); then
        error "Failed to get codename for $file"
    fi
    echo "  Package: $pkgname, Arch: $arch, Codename: $codename" >&2
    echo "$(get_base_props);package_name=$pkgname;deb.distribution=$codename;deb.component=main;deb.architecture=$arch"
}

get_deb_extra_flags() {
    local file="$1"
    local arch codename
    arch=$(dpkg-deb -f "$file" Architecture)
    if ! codename=$(get_codename_for_deb "$file"); then
        error "Failed to get codename for $file"
    fi
    echo "--deb" "$codename/main/$arch"
}

get_rpm_props() {
    local file="$1"
    local -a metadata
    read -r -a metadata < <(get_rpm_metadata "$file")
    local pkgname="${metadata[0]}"
    local version="${metadata[1]}"
    local arch="${metadata[2]}"
    local dist="${metadata[3]}"
    echo "  Package: $pkgname, Version: $version, Arch: $arch, Dist: $dist" >&2
    echo "$(get_base_props);package_name=$pkgname;rpm.distribution=$dist;rpm.component=main;rpm.architecture=$arch"
}

get_jar_props() {
    local file="$1"
    local group_id="$2"
    local pkgname="$3"
    echo "$(get_base_props);group_id=$group_id;package_name=$pkgname"
}

get_nupkg_props() {
    local file="$1"
    local -a metadata
    read -r -a metadata < <(get_nupkg_metadata "$file")
    local pkgname="${metadata[0]}"
    echo "$(get_base_props);package_name=$pkgname"
}

get_npm_props() {
    local file="$1"
    local -a metadata
    read -r -a metadata < <(get_npm_metadata "$file")
    local pkgname="${metadata[0]}"
    echo "  Package: $pkgname" >&2
    echo "$(get_base_props);package_name=$pkgname"
}

get_pypi_props() {
    local file="$1"
    local -a metadata
    read -r -a metadata < <(get_pypi_metadata "$file")
    local pkgname="${metadata[0]}"
    local pkgversion="${metadata[1]}"
    echo "  Package: $pkgname, Version: $pkgversion" >&2
    echo "$(get_base_props);package_name=$pkgname;pypi.name=$pkgname;pypi.version=$pkgversion"
}

get_generic_props() {
    local file="$1"
    local filename
    filename=$(basename "$file")
    echo "$(get_base_props);package_name=$filename"
}
