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
    local filename="${jar##*/}"  # Get just the filename without path
    local pkgname version group_id
    local pom_props

    # Initial parsing - handle versions with SNAPSHOT, SNAPSHOT_<hash>, etc.
    pkgname=$(echo "$filename" | sed -E 's/-[0-9][0-9A-Za-z._\-]*\.jar$//')
    version=$(echo "$filename" | sed -E 's/^[^-]+-([0-9][0-9A-Za-z._\-]*)\.jar$/\1/')

    pom_props=$(unzip -Z1 "$jar" | awk '/pom\.properties$/ {print; exit}')
    if [[ -n "$pom_props" ]]; then
        pkgname=$(unzip -p "$jar" "$pom_props" | grep '^artifactId=' | cut -d= -f2)
        version=$(unzip -p "$jar" "$pom_props" | grep '^version=' | cut -d= -f2)
        group_id=$(unzip -p "$jar" "$pom_props" | grep '^groupId=' | cut -d= -f2)
    else
        # Fallback to filename parsing if pom.properties is not found
        pkgname=$(echo "$filename" | sed -E 's/-[0-9][0-9A-Za-z._\-]*\.jar$//')
        version=$(echo "$filename" | sed -E 's/^[^-]+-([0-9][0-9A-Za-z._\-]*)\.jar$/\1/')
        group_id=""
    fi

    # Return package name, version, and group_id
    echo "$pkgname $version $group_id"
}

# Function to extract RPM metadata and distribution
# Unlike for debs this requires parsing the name (because the distro name is not standard)
get_rpm_metadata() {
    local rpm="$1"
    local filename="${rpm##*/}"  # Get just the filename without path
    
    # Extract distribution from filename first
    # Example: aerospike-server-community-7.2.0.10-1.el9.x86_64
    # We want to extract 'el9' from the filename
    local dist="${filename%.*}"  # Remove the last part (x86_64)
    dist="${dist%.*}"          # Remove the last part (el9)
    dist="${dist##*.}"         # Get the distribution (el9)
    
    # Then get package metadata directly from the RPM file
    local pkgname version arch
    pkgname=$(rpm -qp --qf '%{NAME}' "$rpm")
    version=$(rpm -qp --qf '%{VERSION}' "$rpm")  # Just get VERSION without RELEASE
    arch=$(rpm -qp --qf '%{ARCH}' "$rpm")
    
    # Return the values in a way that can be captured
    echo "$pkgname $version $arch $dist"
}

process_rpm() {
    local rpm="$1"
    local dest_dir="$2"
    local -a metadata
    local pkgname version arch dist
    
    # Get metadata using the new function
    read -r -a metadata < <(get_rpm_metadata "$rpm")
    pkgname="${metadata[0]}"
    version="${metadata[1]}"
    arch="${metadata[2]}"
    dist="${metadata[3]}"
    
    # Create target directory: <dist>/<arch>/
    # Example: el8/x86_64/
    local target="$dest_dir/$dist/$arch"
    echo "DEBUG: Creating directory structure:" >&2
    echo "  Distribution: $dist" >&2
    echo "  Architecture: $arch" >&2
    echo "  Target path: $target" >&2
    mkdir -p "$target"
    echo "Copying RPM to: $target" >&2
    rpm_name=$(basename "$rpm")
    cp -v "$rpm" "$target/$rpm_name" >&2
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
    group_id="${metadata[2]:-}"
    group_path="${group_id:+${group_id//./\/}}"

    local target="$dest_dir/$group_path/$pkgname/$version"
    echo "DEBUG: Creating directory structure:" >&2
    echo "  Group id: $group_id" >&2
    echo "  Package name: $pkgname" >&2
    echo "  Version: $version" >&2
    mkdir -p "$target"
    
    # Get the directory and base name of the jar file
    local jar_dir
    local jar_name
    local base_name
    jar_dir=$(dirname "$jar")
    jar_name=$(basename "$jar")
    base_name="${jar_name%.jar}"  # Remove .jar extension
    
    echo "Copying Maven artifacts to: $target" >&2
    
    # Copy jar, pom, and asc files
    for ext in jar pom jar.asc pom.asc; do
        local file="$jar_dir/${base_name}.${ext}"
        if [[ -f "$file" ]]; then
            cp -v "$file" "$target/" >&2
        fi
    done
}

get_codename_for_deb() {
  case "$1" in
    *ubuntu20.04*) echo "focal" ;;
    *ubuntu22.04*) echo "jammy" ;;
    *ubuntu24.04*) echo "noble" ;;
    *debian11*)    echo "bullseye" ;;
    *debian12*)    echo "bookworm" ;;
    *debian13*)    echo "trixie" ;;
    *) echo "distro $1 not supported" >&2 ; return 1 ;;
  esac
}

process_deb() {
    local deb="$1"
    local dest_dir="$2"
    local codename pkgname arch deb_name
    codename=$(get_codename_for_deb "$deb")
    
    # Get package metadata directly from the DEB file
    pkgname=$(dpkg-deb -f "$deb" Package)
    arch=$(dpkg-deb -f "$deb" Architecture)
    
    local target="$dest_dir/pool/$codename/$pkgname"
    mkdir -p "$target"
    echo "Copying DEB to: $target" >&2
    deb_name=$(basename "$deb")
    cp -v "$deb" "$target/$deb_name" >&2
    echo "$target/$deb_name"
}

# Function to extract NuGet package metadata
get_nupkg_metadata() {
    local nupkg="$1"
    local filename="${nupkg##*/}"
    local pkgname version

    # First, try to extract from .nuspec inside the package
    if command -v unzip >/dev/null 2>&1 && [[ -f "$nupkg" ]]; then
        local nuspec
        nuspec=$(unzip -Z1 "$nupkg" 2>/dev/null | grep -E '\.nuspec$' | head -n1)
        if [[ -n "$nuspec" ]]; then
            pkgname=$(unzip -p "$nupkg" "$nuspec" 2>/dev/null | grep -oP '<id>\K[^<]+' | head -n1)
            version=$(unzip -p "$nupkg" "$nuspec" 2>/dev/null | grep -oP '<version>\K[^<]+' | head -n1)
            if [[ -n "$pkgname" ]] && [[ -n "$version" ]]; then
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

    if [[ -n "$version" ]]; then
        # Package name is everything before the version
        # quoting because of shellchk rules.
        pkgname="${base%."${version}"}"
    else
        # Last resort: use filename without extension
        pkgname="$base"
        version="unknown"
    fi

    echo "$pkgname $version"
}

process_nupkg() {
    local nupkg="$1"
    local dest_dir="$2"
    local nupkg_dir
    nupkg_dir=$(dirname "$nupkg")
    local nupkg_basename
    nupkg_basename=$(basename "$nupkg")
    local base_name="${nupkg_basename%.nupkg}"
    base_name="${base_name%.snupkg}"

    process_generic "$nupkg" "$dest_dir"

    if [[ "$nupkg_dir" == "build-artifacts" ]]; then
        local csproj_file="build-artifacts/${base_name}.csproj"
    else
        local csproj_file="${nupkg_dir}/${base_name}.csproj"
    fi

    if [[ -f "$csproj_file" ]]; then
        echo "Copying .csproj file: $csproj_file" >&2
        process_generic "$csproj_file" "$dest_dir"
    fi
}

process_generic() {
    local file="$1"
    local dest_dir="$2"

    local dir
    dir=$(dirname "$file")
    # Strip "build-artifacts" prefix to preserve only relative path within build-artifacts

    if [[ "$dir" == "build-artifacts" ]]; then
        # File is at root of build-artifacts, no subdirectory
        cp -v "$file" "$dest_dir/" >&2
    else
        # Strip "build-artifacts/" prefix for subdirectories if present
        dir="${dir#build-artifacts/}"
        mkdir -p "$dest_dir/$dir"
        cp -v "$file" "$dest_dir/$dir" >&2
    fi
}
