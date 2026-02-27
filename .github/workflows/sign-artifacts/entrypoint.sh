#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_GLOB="${1-}"
TARGET_DIR="${2-}"
# Set environment variables — allow overrides for local testing
export HOME="${HOME:-/home/runner}"
export GNUPGHOME="${GNUPGHOME:-$HOME/.gnupg}"
export GPG_TTY="${GPG_TTY:-/dev/null}"

echo "Expanding glob pattern: $ARTIFACT_GLOB"
shopt -s globstar nullglob #  Necessary options for globbing

# Create symlink for gpg2 (required for rpm signing)
GPG_PATH=$(which gpg)
ln -sf "$GPG_PATH" /usr/bin/gpg2 2>/dev/null || true

# Validate the glob pattern to ensure it is safe
if [[ -z $ARTIFACT_GLOB || $ARTIFACT_GLOB =~ [^a-zA-Z0-9._*/?{},-] ]]; then
    echo "Invalid glob pattern: $ARTIFACT_GLOB"
    exit 1
fi

eval "FILES=( $ARTIFACT_GLOB )"
if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "No matching artifacts found for pattern: $ARTIFACT_GLOB"
    exit 1
fi
# Debug: Print what files were found
echo "Debug: Found ${#FILES[@]} files matching pattern '$ARTIFACT_GLOB':"
printf '  %s\n' "${FILES[@]}"

mkdir -p "$TARGET_DIR"

for file in "${FILES[@]}"; do
    if [[ -f $file ]]; then
        cp -v --parents "$file" "$TARGET_DIR/"
    else
        echo "not copying $file (directory?)"
    fi

done

# Process all files in the target directory
echo "Processing all files in target directory: $TARGET_DIR"
echo "Target directory contents:"
ls -la "$TARGET_DIR"
find "$TARGET_DIR" -type f | while read -r file; do
    echo "Processing: $file"

    # Skip signature and checksum files to prevent infinite loops
    if [[ $file =~ \.(asc|sha256)$ ]]; then
        continue
    fi

    ext="${file##*.}"

    # Sign .deb files
    if [[ $ext == "deb" ]]; then
        if command -v dpkg-sig &>/dev/null; then
            echo "Signing DEB with dpkg-sig"
            dpkg-sig --sign builder --gpg-options "--batch --pinentry-mode loopback --passphrase-file $GNUPGHOME/passphrase --quiet" "$file"
        else
            echo "ERROR: dpkg-sig not found"
            exit 1
        fi
    fi

    # Sign .rpm files
    if [[ $ext == "rpm" ]]; then
        if command -v rpm &>/dev/null; then
            echo "Signing RPM with rpm --addsign"
            rpm --addsign "$file" 2>/dev/null
        else
            echo "ERROR: 'rpm' not found"
        fi
    fi

    # Always create detached GPG signature for all files
    gpg --detach-sign --no-tty --batch --yes --quiet \
        --passphrase-file "$GNUPGHOME/passphrase" \
        --output "$file.asc" "$file"

    echo "Signed: $file"
    echo "  Signature: $file.asc"
done
