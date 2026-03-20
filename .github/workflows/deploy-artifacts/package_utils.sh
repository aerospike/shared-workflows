#!/usr/bin/env bash
set -euo pipefail
export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
trap 'handle_error ${LINENO}' ERR

handle_error() {
    local exit_code=$?
    local line_number=$1
    echo "Error: Command failed with exit code $exit_code at line $line_number" >&2
    exit 1
}

# Function to extract JAR metadata
get_jar_metadata() {
    local jar="$1"
    local filename="${jar##*/}"
    local jar_dir
    jar_dir="$(dirname "$jar")"
    local pkgname version group_id=""
    local pom_props

    local base_no_ext="${filename%.jar}"

    version=$(echo "$base_no_ext" | sed -E 's/^.*-([0-9][0-9A-Za-z._-]+)-(javadoc|sources)$/\1/')

    pkgname=$(echo "$base_no_ext" | sed -E "s/-${version}(-javadoc|-sources)?$//")

    # Try reading from pom.properties inside the jar
    pom_props=$(unzip -Z1 "$jar" | awk '/pom\.properties$/ {print; exit}')
    if [[ -n $pom_props ]]; then
        pkgname=$(unzip -p "$jar" "$pom_props" | grep '^artifactId=' | cut -d= -f2)
        version=$(unzip -p "$jar" "$pom_props" | grep '^version=' | cut -d= -f2)
        group_id=$(unzip -p "$jar" "$pom_props" | grep '^groupId=' | cut -d= -f2)
    fi

    # If groupId is still empty (e.g., javadoc/sources jars), locate main artifact in same folder
    if [[ -z $group_id ]]; then
        local main_jar=""
        for candidate_jar in "$jar_dir/$pkgname"-*.jar; do
            [ -e "$candidate_jar" ] || continue
            if [[ $candidate_jar != *javadoc* && $candidate_jar != *sources* ]]; then
                main_jar="$candidate_jar"
                break
            fi
        done

        if [[ -f $main_jar && $main_jar != "$jar" ]]; then
            pom_props=$(unzip -Z1 "$main_jar" 2>/dev/null | awk '/pom\.properties$/ {print; exit}')
            if [[ -n $pom_props ]]; then
                group_id=$(unzip -p "$main_jar" "$pom_props" | grep '^groupId=' | cut -d= -f2)
            fi
        fi
    fi

    # Return pkgname, version, groupId
    echo "$pkgname $version $group_id"
}

# Function to extract RPM metadata and distribution
# Unlike for debs this requires parsing the name (because the distro name is not standard)
get_rpm_metadata() {
    local rpm="$1"
    local filename="${rpm##*/}" # Get just the filename without path

    # Extract distribution from filename first
    # Example: aerospike-server-community-7.2.0.10-1.el9.x86_64
    # We want to extract 'el9' from the filename
    local dist="${filename%.*}" # Remove the last part (x86_64)
    dist="${dist%.*}"           # Remove the last part (el9)
    dist="${dist##*.}"          # Get the distribution (el9)

    # Then get package metadata directly from the RPM file
    local pkgname version arch
    pkgname=$(rpm -qp --qf '%{NAME}' "$rpm")
    version=$(rpm -qp --qf '%{VERSION}' "$rpm") # Just get VERSION without RELEASE
    arch=$(rpm -qp --qf '%{ARCH}' "$rpm")

    # Return the values in a way that can be captured
    echo "$pkgname $version $arch $dist"
}

process_rpm() {
    local file="$1"
    local dest_dir="$2"
    local -a metadata
    local pkgname version arch dist

    read -r -a metadata < <(get_rpm_metadata "$file")
    pkgname="${metadata[0]}"
    version="${metadata[1]}"
    arch="${metadata[2]}"
    dist="${metadata[3]}"

    local target="$dest_dir/$dist/$arch"
    echo "  Distribution: $dist, Architecture: $arch" >&2
    mkdir -p "$target"
    echo "Copying RPM to: $target" >&2
    local rpm_name
    rpm_name=$(basename "$file")
    cp -v "$file" "$target/$rpm_name" >&2
    # Return target path for companion placement
    echo "$target/$rpm_name"
}

process_jar() {
    local jar="$1"
    local dest_dir="$2"
    local -a metadata
    local pkgname version group_id group_path

    # Get metadata using the new function
    read -r -a metadata < <(get_jar_metadata "$jar")
    pkgname="${metadata[0]}"
    version="${metadata[1]}"
    # Use :- to handle empty group_id (when array may only have 2 elements due to trailing space trimming)
    group_id="${metadata[2]-}"
    group_path="${group_id:+${group_id//./\/}}"

    local target="$dest_dir/$group_path/$pkgname/$version"
    echo "DEBUG: Creating directory structure:" >&2
    echo "  Group id: $group_id" >&2
    echo "  Package name: $pkgname" >&2
    echo "  Version: $version" >&2
    mkdir -p "$target"

    local jar_name
    jar_name=$(basename "$jar")

    echo "Copying JAR to: $target" >&2
    cp -v "$jar" "$target/" >&2
    # Return target path
    echo "$target/$jar_name"
}

get_codename_for_deb() {
    case "$1" in
    *ubuntu20.04*) echo "focal" ;;
    *ubuntu22.04*) echo "jammy" ;;
    *ubuntu24.04*) echo "noble" ;;
    *debian11*) echo "bullseye" ;;
    *debian12*) echo "bookworm" ;;
    *debian13*) echo "trixie" ;;
    *)
        echo "distro $1 not supported" >&2
        return 1
        ;;
    esac
}

process_deb() {
    local file="$1"
    local dest_dir="$2"
    local codename pkgname

    codename=$(get_codename_for_deb "$file")
    pkgname=$(dpkg-deb -f "$file" Package)

    local target="$dest_dir/pool/$codename/$pkgname"
    mkdir -p "$target"
    echo "Copying DEB to: $target" >&2
    local deb_name
    deb_name=$(basename "$file")
    cp -v "$file" "$target/$deb_name" >&2
    echo "$target/$deb_name"
}

# Function to extract NuGet package metadata
get_nupkg_metadata() {
    local nupkg="$1"
    local filename="${nupkg##*/}"
    local pkgname version

    # First, try to extract from .nuspec inside the package
    if command -v unzip >/dev/null 2>&1 && [[ -f $nupkg ]]; then
        local nuspec
        nuspec=$(unzip -Z1 "$nupkg" 2>/dev/null | grep -E '\.nuspec$' | head -n1)
        if [[ -n $nuspec ]]; then
            pkgname=$(unzip -p "$nupkg" "$nuspec" 2>/dev/null | grep -oP '<id>\K[^<]+' | head -n1)
            version=$(unzip -p "$nupkg" "$nuspec" 2>/dev/null | grep -oP '<version>\K[^<]+' | head -n1)
            if [[ -n $pkgname ]] && [[ -n $version ]]; then
                echo "$pkgname $version"
                return
            fi
        fi
    fi

    # Fallback: extract from filename
    # NuGet package filename format: PackageName.Version.nupkg
    # Remove extension first, then extract version (last sequence matching version pattern)
    local base="${filename%.nupkg}"
    base="${base%.snupkg}"

    # Extract version: find the last dot-separated segment that starts with a digit
    # Version pattern: starts with digit, may contain dots, dashes, and alphanumeric
    version=$(echo "$base" | grep -oE '[0-9]+(\.[0-9]+)+(-[0-9A-Za-z._\-]+)?$' || echo "")

    if [[ -n $version ]]; then
        # Package name is everything before the version
        # quoting because of shellcheck rules.
        pkgname="${base%."${version}"}"
    else
        # Last resort: use filename without extension
        pkgname="$base"
        version="unknown"
    fi

    echo "$pkgname $version"
}

# Copy a file to dest_dir, preserving its relative path within build-artifacts/.
# Additional prefixes (e.g. "unsigned-artifacts") can be stripped via extra arguments.
# Usage: copy_to_structured <file> <dest_dir> [prefix_to_strip ...]
copy_to_structured() {
    local file="$1" dest_dir="$2"
    shift 2

    local dir
    dir=$(dirname "$file")
    dir="${dir#build-artifacts/}"
    dir="${dir#build-artifacts}"
    for prefix in "$@"; do
        dir="${dir#"$prefix"/}"
        dir="${dir#"$prefix"}"
    done

    local target_file
    target_file="$dest_dir/$(basename "$file")"
    if [[ -n $dir && $dir != "." ]]; then
        mkdir -p "$dest_dir/$dir"
        cp -v "$file" "$dest_dir/$dir" >&2
        target_file="$dest_dir/$dir/$(basename "$file")"
    else
        cp -v "$file" "$dest_dir/" >&2
    fi
    echo "$target_file"
}

process_nupkg() { copy_to_structured "$1" "$2"; }

# Extract the package.json content from an npm tarball.
# npm tarballs have a single root directory containing package.json.
# The root dir is typically "package/" (npm pack) but can vary (yarn pack, manual builds).
# Returns the JSON on stdout, or returns 1 if not found/invalid.
_extract_npm_package_json() {
    local file="$1"

    local pkg_path
    pkg_path=$(tar -tzf "$file" 2>/dev/null | grep -E '^[^/]+/package\.json$' | head -n1) || return 1

    [ -z "$pkg_path" ] && return 1

    tar -xOzf "$file" "$pkg_path" 2>/dev/null
}

# Check if a .tgz file is an npm package.
# Validates that the tarball contains a root-level package.json with name and version fields.
is_npm_package() {
    local file="$1"
    _extract_npm_package_json "$file" |
        jq -e '.name and .version' >/dev/null 2>&1
}

# Validate an npm package name.
# npm names must be lowercase, may be scoped (@scope/name), and contain only
# alphanumerics, hyphens, dots, underscores, and tildes. Rejects names with
# semicolons or other characters that could inject JFrog target-props.
_validate_npm_name() {
    local name="$1"
    if [[ ! $name =~ ^(@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*$ ]]; then
        error "Invalid npm package name: '$name'"
    fi
}

# Extract npm package metadata (name and version).
# Caller must ensure the file is a valid npm package (via is_npm_package).
get_npm_metadata() {
    local tgz="$1"

    local pkg_json
    pkg_json=$(_extract_npm_package_json "$tgz") || error "Failed to extract package.json from $tgz"

    local pkgname version
    pkgname=$(echo "$pkg_json" | jq -r '.name')
    version=$(echo "$pkg_json" | jq -r '.version')

    _validate_npm_name "$pkgname"

    echo "$pkgname $version"
}

process_npm() { copy_to_structured "$1" "$2"; }

# Generic strips the extra "unsigned-artifacts" prefix leaked from the sign stage's cp --parents
process_generic() { copy_to_structured "$1" "$2" "unsigned-artifacts"; }
