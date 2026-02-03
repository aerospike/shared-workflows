#!/bin/bash

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
VERSION="1.0.0"
TARGET="hi"
PACKAGES_DIR="packages"
OUTPUT_DIR="packaged"

show_help() {
    echo "Usage: $0 [OPTIONS]" >&2
    echo "" >&2
    echo "Package binaries into DEB and RPM packages" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --version <version>           Package version (default: 1.0.0)" >&2
    echo "  --target <name>               Binary target name (default: hi)" >&2
    echo "  --packages-dir <dir>          Directory containing binaries (default: packages)" >&2
    echo "  --output-dir <dir>            Output directory for packages (default: packaged)" >&2
    echo "  --help, -h                    Show this help message" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 --version 2.0.0 --target myapp" >&2
    echo "  $0 --packages-dir build --output-dir dist" >&2
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
    --version)
        VERSION="$2"
        shift 2
        ;;
    --target)
        TARGET="$2"
        shift 2
        ;;
    --packages-dir)
        PACKAGES_DIR="$2"
        shift 2
        ;;
    --output-dir)
        OUTPUT_DIR="$2"
        shift 2
        ;;
    --help | -h)
        show_help
        exit 0
        ;;
    -*)
        echo "Unknown option: $1" >&2
        show_help
        exit 1
        ;;
    *)
        echo "Unexpected positional argument: $1" >&2
        show_help
        exit 1
        ;;
    esac
done

set -euo pipefail

# FPM options
FPM_OPTS=(--verbose --force --maintainer="Aerospike Team" --description="Simple hello world app" --version="$VERSION" --vendor="Aerospike" --name="$TARGET")

# Distro version mapping
declare -A DISTRO_VERSIONS=(
    [jammy]="ubuntu22.04"
    [noble]="ubuntu24.04"
    [focal]="ubuntu20.04"
    [bullseye]="debian11"
    [bookworm]="debian12"
    [trixie]="debian13"
    [el8]="el8"
    [el9]="el9"
    [amzn2023]="amzn2023"
)
install_fpm() {
    sudo apt-get update
    sudo apt-get install -y ruby-dev build-essential
    sudo gem install fpm
}

# Function to create DEB package
create_deb_package() {
    local distro="$1"
    local arch="$2"
    local binary_path="$3"
    local distro_version="${DISTRO_VERSIONS[$distro]}"
    local package_name="${TARGET}_${VERSION}_${distro_version}_${arch}.deb"
    local output_path="$OUTPUT_DIR/$package_name"

    echo "Creating DEB package: $package_name"
    echo "  Binary: $binary_path"
    echo "  Output: $output_path"

    fpm -s dir -t deb "${FPM_OPTS[@]}" \
        --package="$output_path" \
        --deb-dist="$distro" \
        --deb-use-file-permissions \
        "$binary_path=/usr/local/bin/$TARGET"
}

# Function to create RPM package
create_rpm_package() {
    local distro="$1"
    local arch="$2"
    local binary_path="$3"
    local distro_version="${DISTRO_VERSIONS[$distro]}"

    local package_name="${TARGET}-${VERSION}-1.${distro_version}.${arch}.rpm"
    local output_path="$OUTPUT_DIR/$package_name"

    echo "Creating RPM package: $package_name"
    echo "  Binary: $binary_path"
    echo "  Output: $output_path"

    fpm -s dir -t rpm "${FPM_OPTS[@]}" \
        --package="$output_path" \
        --rpm-use-file-permissions \
        "$binary_path=/usr/local/bin/$TARGET"
}

main() {
    echo "Packaging $TARGET application"
    echo "Version: $VERSION"
    echo "Packages directory: $PACKAGES_DIR"
    echo "Output directory: $OUTPUT_DIR"
    echo ""
    install_fpm
    # Check if packages directory exists
    if [[ ! -d $PACKAGES_DIR ]]; then
        error "Packages directory not found: $PACKAGES_DIR"
    fi

    # Create output directory
    mkdir -p "$OUTPUT_DIR"

    # Find all binaries and process them
    while IFS= read -r -d '' binary; do
        local rel_path="${binary#"$PACKAGES_DIR/"}"
        local distro_arch="${rel_path%/"$TARGET"}"
        local distro="${distro_arch%/*}"
        local arch="${distro_arch#*/}"

        echo "Processing: $binary"
        echo "  Distro: $distro"
        echo "  Arch: $arch"

        if [[ ! -x $binary ]]; then
            chmod +x "$binary"
        fi

        if [[ ! -v DISTRO_VERSIONS[$distro] ]]; then
            error "Unknown distro: $distro"
        fi

        case "$distro" in
        el* | amzn*)
            create_rpm_package "$distro" "$arch" "$binary"
            ;;
        *)
            create_deb_package "$distro" "$arch" "$binary"
            ;;
        esac
        echo ""
    done < <(find "$PACKAGES_DIR" -name "$TARGET" -type f -print0)

    echo "Packaging complete!"
    echo ""
    echo "Generated packages:"
    find "$OUTPUT_DIR" -name "*.deb" -o -name "*.rpm" | sort
}

main "$@"
