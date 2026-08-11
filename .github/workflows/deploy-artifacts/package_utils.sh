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

    # Flat JAR + sibling POM (e.g. test.jar + test.pom): filename may not encode version.
    # _maven_read_pom_coordinates (../lib/maven-helpers.sh) resolves parent inheritance;
    # only overwrite filename-derived fields when the POM supplies non-empty values.
    local sibling_pom="$jar_dir/${base_no_ext}.pom"
    if [[ -z $group_id && -f $sibling_pom ]]; then
        if command -v xmllint >/dev/null 2>&1; then
            local pom_artifact_id pom_group_id pom_version _pom_packaging _pom_module_count
            read -r pom_artifact_id pom_group_id pom_version _pom_packaging _pom_module_count \
                < <(_maven_read_pom_coordinates "$sibling_pom")
            [[ -n $pom_artifact_id ]] && pkgname="$pom_artifact_id"
            [[ -n $pom_version ]] && version="$pom_version"
            [[ -n $pom_group_id ]] && group_id="$pom_group_id"
        fi
    fi

    # If groupId is still empty (e.g., javadoc/sources jars), locate main artifact in same folder
    if [[ -z $group_id ]]; then
        local main_jar=""
        shopt -s nullglob
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
        shopt -u nullglob
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

    local jar_name jar_dir base_name
    jar_name=$(basename "$jar")
    jar_dir=$(dirname "$jar")
    base_name="${jar_name%.jar}"

    echo "Copying JAR to: $target" >&2
    cp -v "$jar" "$target/" >&2

    # Maven companions: pom and checksum sidecars share the JAR's stem (not its
    # full filename), so the generic gather_companions cannot find them. Copy
    # them here so they land in the same structured target as the JAR.
    # .md5/.sha1 are deliberately NOT signed per Maven Central convention;
    # any .md5.asc/.sha1.asc produced by an indiscriminate sign step is
    # intentionally left behind here so it doesn't reach JFrog.
    # Order isn't important during structuring; the upload step controls upload
    # order so JFrog's checksum-deploy interception finds the base file first.
    for ext in pom pom.asc \
        jar.md5 jar.sha1 pom.md5 pom.sha1; do
        local sibling="$jar_dir/${base_name}.${ext}"
        if [[ -f $sibling ]]; then
            cp -v "$sibling" "$target/" >&2
        fi
    done

    # Return target path
    echo "$target/$jar_name"
}

get_codename_for_deb() {
    case "$1" in
    *ubuntu20.04*) echo "focal" ;;
    *ubuntu22.04*) echo "jammy" ;;
    *ubuntu24.04*) echo "noble" ;;
    *ubuntu26.04*) echo "resolute" ;;
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

# Copy a file to dest_dir, preserving its relative path within the artifacts tree.
# BUILD_ARTIFACTS_DIR (default: build-artifacts) must match the directory find uses as root.
# Additional prefixes (e.g. "unsigned-artifacts") can be stripped via extra arguments.
# Usage: copy_to_structured <file> <dest_dir> [prefix_to_strip ...]
copy_to_structured() {
    local file="$1" dest_dir="$2"
    shift 2

    local artifacts_root="${BUILD_ARTIFACTS_DIR:-build-artifacts}"
    # Strip the slash, just in case
    artifacts_root="${artifacts_root%/}"
    local dir
    dir=$(dirname "$file")
    dir="${dir#"$artifacts_root"/}"
    dir="${dir#"$artifacts_root"}"
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

# Structure a NuGet package into the destination directory.
# Args: <file> <dest_dir>
# Returns: target path on stdout.
process_nupkg() { copy_to_structured "$1" "$2"; }

# Extract the package.json content from an npm tarball.
# npm tarballs have a single root directory containing package.json.
# The root dir is typically "package/" (npm pack) but can vary (yarn pack, manual builds).
# Args: <tgz_file>
# Returns: the JSON on stdout, or returns 1 if not found/invalid.
_extract_npm_package_json() {
    local file="$1"

    local pkg_path
    pkg_path=$(tar -tzf "$file" 2>/dev/null | grep -E '^[^/]+/package\.json$' | head -n1) || return 1

    [ -z "$pkg_path" ] && return 1

    tar -xOzf "$file" "$pkg_path" 2>/dev/null
}

# Validate an npm package name.
# npm names must be lowercase, may be scoped (@scope/name), and contain only
# alphanumerics, hyphens, dots, underscores, and tildes. Rejects names with
# semicolons or other characters that could inject JFrog target-props.
# Args: <name>
# Exits with error if invalid.
_validate_npm_name() {
    local name="$1"
    if [[ ! $name =~ ^(@[a-z0-9][a-z0-9._~-]*/)?[a-z0-9][a-z0-9._~-]*$ ]]; then
        error "Invalid npm package name: '$name'"
    fi
}

# Extract npm package metadata (name and version).
# Caller must ensure the file is a valid npm package (via is_npm_package in type_detection.sh).
# Args: <tgz_file>
# Returns: "name version" on stdout.
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

# Structure an npm package into the destination directory.
# Args: <file> <dest_dir>
# Returns: target path on stdout.
process_npm() { copy_to_structured "$1" "$2"; }

# --- PyPI (Python) package functions ---

# Validate a Python package name against PEP 508 naming rules.
# Rejects names that could inject JFrog target-props (semicolons, etc.).
# Args: <name>
# Exits with error if invalid.
_validate_pypi_name() {
    local name="$1"
    if [[ ! $name =~ ^[A-Za-z0-9]([A-Za-z0-9._-]*[A-Za-z0-9])?$ ]]; then
        error "Invalid Python package name: '$name'"
    fi
}

# Normalize a Python package name per PEP 503.
# Replaces runs of [-_.] with single hyphen, lowercases.
# Args: <name>
# Returns: normalized name on stdout.
_normalize_pypi_name() {
    local name="$1"
    echo "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[-_.]+/-/g'
}

# Extract metadata from a wheel file.
# Parses filename first, then overrides from .dist-info/METADATA if available.
# Args: <whl_file>
# Returns: "name version" on stdout.
_get_wheel_metadata() {
    local package="$1"
    local filename="${package##*/}"
    local base="${filename%.whl}"
    local pkgname version

    # Wheel filename: {name}-{version}-{python}-{abi}-{platform}.whl
    # Name and version fields use underscores (never hyphens) in the filename.
    pkgname="${base%%-*}"
    local rest="${base#"$pkgname"-}"
    version="${rest%%-*}"

    # Try to get canonical name from METADATA inside the wheel (ZIP format)
    if command -v unzip >/dev/null 2>&1 && [[ -f $package ]]; then
        local metadata_file
        metadata_file=$(unzip -Z1 "$package" 2>/dev/null | grep -E '\.dist-info/METADATA$' | head -n1)
        if [[ -n $metadata_file ]]; then
            local meta_name meta_version
            meta_name=$(unzip -p "$package" "$metadata_file" 2>/dev/null | grep -m1 -i '^Name:' | cut -d' ' -f2- | tr -d '\r')
            meta_version=$(unzip -p "$package" "$metadata_file" 2>/dev/null | grep -m1 -i '^Version:' | cut -d' ' -f2- | tr -d '\r')
            [[ -n $meta_name ]] && pkgname="$meta_name"
            [[ -n $meta_version ]] && version="$meta_version"
        fi
    fi

    _validate_pypi_name "$pkgname"
    echo "$pkgname $version"
}

# Extract metadata from a Python source distribution (.tar.gz).
# Parses PKG-INFO inside the tarball, falls back to filename.
# Args: <tar_gz_file>
# Returns: "name version" on stdout.
_get_sdist_metadata() {
    local package="$1"
    local filename="${package##*/}"
    local pkgname="" version=""

    # Try to extract from PKG-INFO inside the tarball
    local pkg_info_path
    pkg_info_path=$(tar -tzf "$package" 2>/dev/null | grep -E '^[^/]+/PKG-INFO$' | head -n1)
    if [[ -n $pkg_info_path ]]; then
        pkgname=$(tar -xOzf "$package" "$pkg_info_path" 2>/dev/null | grep -m1 -i '^Name:' | cut -d' ' -f2- | tr -d '\r')
        version=$(tar -xOzf "$package" "$pkg_info_path" 2>/dev/null | grep -m1 -i '^Version:' | cut -d' ' -f2- | tr -d '\r')
    fi

    # Fallback: parse filename ({name}-{version}.tar.gz or .tgz)
    if [[ -z ${pkgname-} ]] || [[ -z ${version-} ]]; then
        # Strip tarball extensions
        local base="${filename%.tar.gz}"
        base="${base%.tgz}"
        if [[ $base =~ ^(.+)-([0-9]+.*)$ ]]; then
            [[ -z ${pkgname-} ]] && pkgname="${BASH_REMATCH[1]}"
            [[ -z ${version-} ]] && version="${BASH_REMATCH[2]}"
        else
            [[ -z ${pkgname-} ]] && pkgname="$base"
            [[ -z ${version-} ]] && version="unknown"
        fi
    fi

    _validate_pypi_name "$pkgname"
    echo "$pkgname $version"
}

# Extract Python package metadata (name and version).
# Dispatches to wheel or sdist handler based on extension.
# Args: <package_file> (.whl, .tar.gz, or .tgz)
# Returns: "name version" on stdout.
get_pypi_metadata() {
    local package="$1"
    local filename="${package##*/}"

    if [[ $filename == *.whl ]]; then
        _get_wheel_metadata "$package"
    elif [[ $filename == *.tar.gz || $filename == *.tgz ]]; then
        _get_sdist_metadata "$package"
    else
        echo "unknown unknown"
    fi
}

# Structure a Python package into the destination directory.
# Args: <file> <dest_dir>
# Returns: target path on stdout.
process_pypi() { copy_to_structured "$1" "$2"; }

# --- Go module functions ---

# Validate a Go module path.
# Go module paths are slash-separated, each element matching [a-zA-Z0-9._~-]+.
# The first element must contain a dot (domain name). Rejects semicolons and other
# characters that could inject JFrog target-props.
# Args: <module_path>
# Exits with error if invalid.
_validate_go_module_path() {
    local path="$1"
    if [[ ! $path =~ ^[a-zA-Z0-9._~/-]+$ ]]; then
        error "Invalid Go module path: '$path'"
    fi
    local first_element="${path%%/*}"
    if [[ $first_element != *.* ]]; then
        error "Invalid Go module path (first element must be a domain): '$path'"
    fi
}

# Extract Go module metadata (module path and version) from a Go module zip.
# Go module zips have entries prefixed with module@version/.
# Use is_go_module (type_detection.sh) before treating a zip as a Go module for routing.
# Args: <zip_file>
# Returns: "module_path version" on stdout.
get_go_metadata() {
    local zip="$1"
    local mod_entry
    mod_entry=$(unzip -Z1 "$zip" 2>/dev/null | grep -E '^[^@]+@v[^/]+/go\.mod$' | head -n1) || return 1
    local prefix="${mod_entry%/go.mod}"
    local module_path="${prefix%@*}"
    local module_version="${prefix##*@}"
    _validate_go_module_path "$module_path"
    echo "$module_path $module_version"
}

# Structure a Go module zip into the destination directory.
# Args: <file> <dest_dir>
# Returns: target path on stdout.
process_go() { copy_to_structured "$1" "$2"; }

# --- Helm chart functions ---
# is_helm_chart and _extract_helm_chart_yaml are defined in ../lib/helm-helpers.sh,
# sourced by entrypoint.sh (and by sign-artifacts/entrypoint.sh) so the two stages
# stay in sync.
#
# get_jar_metadata sibling-POM path uses _maven_read_pom_coordinates from
# ../lib/maven-helpers.sh (sourced before this file in entrypoint.sh / detect_types.sh).

# Validate a Helm chart name.
# Helm chart names use DNS-1123-style identifiers (lowercase, alphanumeric, hyphens,
# dots, underscores). Rejects names with semicolons or other characters that could
# inject JFrog target-props.
# Args: <name>
# Exits with error if invalid.
_validate_helm_name() {
    local name="$1"
    if [[ ! $name =~ ^[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ ]]; then
        error "Invalid Helm chart name: '$name'"
    fi
}

# Extract a single top-level scalar field from Chart.yaml content.
# Strips surrounding single/double quotes, trailing whitespace, inline comments, CRLF.
# Args: <chart_yaml_content> <field_name>
# Returns: the value on stdout, or empty string.
_chart_yaml_field() {
    local content="$1" field="$2"
    awk -v f="^${field}:[[:space:]]*" '
        $0 ~ f {
            sub(f, "")
            sub(/[[:space:]]+#.*$/, "")
            sub(/[[:space:]]+$/, "")
            sub(/^["'\'']/, "")
            sub(/["'\'']$/, "")
            sub(/\r$/, "")
            print
            exit
        }
    ' <<<"$content"
}

# Extract Helm chart metadata (name and version) from a packaged chart .tgz.
# Caller must ensure the file is a valid Helm chart (via is_helm_chart in type_detection.sh).
# Args: <tgz_file>
# Returns: "name version" on stdout.
get_helm_metadata() {
    local tgz="$1"
    local chart_yaml
    chart_yaml=$(_extract_helm_chart_yaml "$tgz") || error "Failed to extract Chart.yaml from $tgz"
    local pkgname version
    pkgname=$(_chart_yaml_field "$chart_yaml" "name")
    version=$(_chart_yaml_field "$chart_yaml" "version")
    _validate_helm_name "$pkgname"
    echo "$pkgname $version"
}

# Structure a Helm chart into the destination directory.
# Args: <file> <dest_dir>
# Returns: target path on stdout.
process_helm() { copy_to_structured "$1" "$2"; }

# --- Rust crate functions ---

# Validate a Rust crate package name (Cargo [package].name).
# Rejects names that could inject JFrog target-props (semicolons, etc.).
# Args: <name>
# Exits with error if invalid.
_validate_crate_name() {
    local name="$1"
    if [[ ! $name =~ ^[a-zA-Z0-9_-]+$ ]]; then
        error "Invalid crate name: '$name'"
    fi
}

# Locate Cargo.toml inside a .crate tarball (single top-level directory).
# Args: <crate_file>
# Returns: member path on stdout, or return 1.
_find_crate_cargo_toml_member() {
    local file="$1"
    tar -tzf "$file" 2>/dev/null | awk '/^[^\/]+\/Cargo\.toml$/ {print; exit}'
}

# Extract Cargo.toml content from a .crate tarball.
# Args: <crate_file>
# Returns: Cargo.toml on stdout, or return 1.
_extract_crate_cargo_toml() {
    local file="$1"
    local cargo_member
    cargo_member=$(_find_crate_cargo_toml_member "$file") || return 1
    [[ -n $cargo_member ]] || return 1
    tar -xOzf "$file" "$cargo_member" 2>/dev/null
}

# Read a scalar field from the [package] section of Cargo.toml content.
# Args: <cargo_toml_content> <field_name>
# Returns: the value on stdout, or empty string.
_cargo_toml_package_field() {
    local content="$1" field="$2"
    awk -v f="$field" '
        /^\[package\]/ { in_pkg=1; next }
        /^\[/ { in_pkg=0 }
        in_pkg && $0 ~ "^" f "[[:space:]]*=" {
            sub("^" f "[[:space:]]*=[[:space:]]*", "")
            sub(/[[:space:]]+#.*$/, "")
            sub(/[[:space:]]+$/, "")
            sub(/^"/, "")
            sub(/"$/, "")
            sub(/^'\''/, "")
            sub(/'\''$/, "")
            print
            exit
        }
    ' <<<"$content"
}

# Extract Rust crate metadata (name and version) from a .crate file.
# Reads [package] name/version from Cargo.toml; falls back to filename parsing.
# Args: <crate_file>
# Returns: "name version" on stdout.
get_crate_metadata() {
    local crate="$1"
    local filename="${crate##*/}"
    local pkgname="" version=""
    local cargo_toml

    cargo_toml=$(_extract_crate_cargo_toml "$crate" 2>/dev/null || true)
    if [[ -n $cargo_toml ]]; then
        pkgname=$(_cargo_toml_package_field "$cargo_toml" "name")
        version=$(_cargo_toml_package_field "$cargo_toml" "version")
    fi

    if [[ -z $pkgname || -z $version ]]; then
        local base="${filename%.crate}"
        if [[ $base =~ ^(.+)-([0-9]+.*)$ ]]; then
            [[ -z $pkgname ]] && pkgname="${BASH_REMATCH[1]}"
            [[ -z $version ]] && version="${BASH_REMATCH[2]}"
        else
            [[ -z $pkgname ]] && pkgname="$base"
            [[ -z $version ]] && version="unknown"
        fi
    fi

    _validate_crate_name "$pkgname"
    echo "$pkgname $version"
}

# Structure a Rust crate into the destination directory.
# Args: <file> <dest_dir>
# Returns: target path on stdout.
process_crate() { process_generic "$1" "$2"; }

# Structure a generic file into the destination directory.
# Strips the "unsigned-artifacts" prefix leaked from the sign stage's cp --parents.
# Args: <file> <dest_dir>
# Returns: target path on stdout.
process_generic() { copy_to_structured "$1" "$2" "unsigned-artifacts"; }

# Structure Windows artifacts (exe, msi, msix); same path rules as generic.
process_win() { process_generic "$1" "$2"; }
