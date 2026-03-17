#!/usr/bin/env bash
# type_registry.sh - Centralized type registry for artifact deployment
#
# To add a new artifact type (eg npm, python, etc):
#   1. Add entries to the associative arrays below
#   2. Add a get_TYPE_props() function
#   3. Add a process_TYPE() function in package_utils.sh (or reuse process_generic)
#   4. Add tests
#
# Required globals (set by entrypoint.sh before sourcing):
#   VERSION, BUILD_NAME, PROJECT, BUILD_TYPE, INTERNAL

# --- Type configuration arrays ---
# These arrays are used by upload_utils.sh and entrypoint.sh (sourced, not executed directly)
# shellcheck disable=SC2034

# Primary file extension pattern per type (used by find in upload_type).
# Generic is NOT listed here -- it's the catch-all handled separately during structuring,
# and uses "*" during upload (since its files are pre-filtered during structuring).
declare -A TYPE_EXTENSIONS=(
    [deb]="*.deb"
    [rpm]="*.rpm"
    [jar]="*.jar"
    [nupkg]="*.nupkg"
    [snupkg]="*.snupkg"
)

# JFrog repository suffix per type
declare -A TYPE_REPO=(
    [deb]="deb-dev-local"
    [rpm]="rpm-dev-local"
    [jar]="maven-dev-local"
    [nupkg]="nuget-dev-local"
    [snupkg]="nuget-dev-local"
    [generic]="generic-dev-local"
)

# Companion file suffixes per type
# During structuring, companions are automatically gathered alongside the primary file.
# During upload, companions are uploaded to the same repo as the primary file.
# For example if there we needed to upload special metadata files for snupkg would wuld add the pattern here
# and they would automatically be included in the upload process without needing to change upload_utils.sh
declare -A TYPE_COMPANIONS=(
    [deb]=".asc"
    [rpm]=".asc"
    [jar]=".pom .asc .pom.asc"
    [nupkg]=".asc"
    [snupkg]=".asc"
    [generic]=".asc"
)

# Structuring destination subdirectory per type
declare -A TYPE_STRUCT_DIR=(
    [deb]="deb"
    [rpm]="rpm"
    [jar]="jar"
    [nupkg]="nupkg"
    [snupkg]="nupkg"
    [generic]="generic"
)

# Upload order matters: jar before generic (jar can move files to generic)
UPLOAD_ORDER=(rpm deb jar nupkg generic)

# --- helpers ---

# Returns the list of all known file extensions (primary + companion + build files).
# Used to build the negated find pattern for generic file discovery.
get_known_extensions() {
    local -a exts=()
    for ext_pattern in "${TYPE_EXTENSIONS[@]}"; do
        exts+=("$ext_pattern")
    done
    # Companion and build file extensions excluded from generic
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

get_generic_props() {
    local file="$1"
    local filename
    filename=$(basename "$file")
    echo "$(get_base_props);package_name=$filename"
}
