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

# Packaging script for hi application
# Takes binaries from packages/<distro>/<arch>/ and creates appropriate packages
# Usage: ./package.sh [version]

set -euo pipefail

VERSION=${1:-1.0.0}

# Configuration
TARGET=hi
PACKAGES_DIR=packages
OUTPUT_DIR=packaged

# FPM options
FPM_OPTS=(--verbose --force --maintainer="Aerospike Team" --description="Simple hello world app" --version="$VERSION" --vendor="Aerospike" --name="$TARGET")

# Distro version mapping
declare -A DISTRO_VERSIONS=(
    [jammy]="ubuntu22.04"
    [noble]="ubuntu24.04"
    [focal]="ubuntu20.04"
    [bullseye]="debian11"
    [bookworm]="debian12"
    [el8]="el8"
    [el9]="el9"
    [amzn2023]="amzn2023"
)

# Function to create DEB package
create_deb_package() {
    local distro="$1"
    local arch="$2"
    local binary_path="$3"
    local version="${DISTRO_VERSIONS[$distro]}"
    
    local package_name="${TARGET}_${VERSION}_${version}_${arch}.deb"
    local output_path="$OUTPUT_DIR/$package_name"
    
    echo "Creating DEB package: $package_name"
    echo "  Binary: $binary_path"
    echo "  Output: $output_path"
    
    fpm -s dir -t deb "${FPM_OPTS[@]}" \
        --package="$output_path" \
        --deb-dist="$distro" \
        "$binary_path=/usr/local/bin/$TARGET"
}

# Function to create RPM package
create_rpm_package() {
    local distro="$1"
    local arch="$2"
    local binary_path="$3"
    local version="${DISTRO_VERSIONS[$distro]}"
    
    local package_name="${TARGET}-${VERSION}-1.${version}.${arch}.rpm"
    local output_path="$OUTPUT_DIR/$package_name"
    
    echo "Creating RPM package: $package_name"
    echo "  Binary: $binary_path"
    echo "  Output: $output_path"
    
    fpm -s dir -t rpm "${FPM_OPTS[@]}" \
        --package="$output_path" \
        "$binary_path=/usr/local/bin/$TARGET"
}

# Function to process a single binary
process_binary() {
    local binary_path="$1"
    local rel_path="${binary_path#"$PACKAGES_DIR/"}"

    local distro_arch="${rel_path%/"$TARGET"}"
    local distro="${distro_arch%/*}"
    local arch="${distro_arch#*/}"
    
    echo "Processing: $binary_path"
    echo "  Distro: $distro"
    echo "  Arch: $arch"
    
    if [[ ! -v DISTRO_VERSIONS[$distro] ]]; then
        echo "ERROR: Unknown distro: $distro"
        return 1
    fi
    
    case "$distro" in
        el*|amzn*)
            create_rpm_package "$distro" "$arch" "$binary_path"
            ;;
        *)
            create_deb_package "$distro" "$arch" "$binary_path"
            ;;
    esac
}

# Main function
main() {
    echo "Packaging hi application"
    echo "Version: $VERSION"
    echo "Packages directory: $PACKAGES_DIR"
    echo "Output directory: $OUTPUT_DIR"
    echo ""
    
    # Check if packages directory exists
    if [[ ! -d "$PACKAGES_DIR" ]]; then
        echo "ERROR: Packages directory not found: $PACKAGES_DIR"
        exit 1
    fi
    
    # Create output directory
    mkdir -p "$OUTPUT_DIR"
    
    # Find all binaries and process them
    local binary_count=0
    local error_count=0
    
    while IFS= read -r -d '' binary; do
        echo ""
        if process_binary "$binary"; then
            ((binary_count++)) || true
        else
            ((error_count++)) || true
        fi
    done < <(find "$PACKAGES_DIR" -name "$TARGET" -type f -print0)
    
    echo ""
    echo "Packaging complete!"
    echo "  Binaries processed: $binary_count"
    echo "  Errors: $error_count"
    
    echo ""
    echo "Generated packages:"
    find "$OUTPUT_DIR" -name "*.deb" -o -name "*.rpm" | sort
}

# Show usage
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: $0 [version]"
    echo ""
    echo "Arguments:"
    echo "  version   Package version (default: 1.0.0)"
    echo ""
    echo "Examples:"
    echo "  $0         # Package with version 1.0.0"
    echo "  $0 2.0.0   # Package with version 2.0.0"
    exit 0
fi

# Run main function
main "$@"
