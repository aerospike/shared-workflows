#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_GLOB="${1:-}"
# Set environment variables consistent with test workflows
export HOME="/home/runner"
export GNUPGHOME="/home/runner/.gnupg"
export GPG_TTY="/dev/null"

echo "Expanding glob pattern: $ARTIFACT_GLOB"
shopt -s globstar nullglob #  Necessary options for globbing

# Expand the glob pattern into an array
eval "FILES=( $ARTIFACT_GLOB )"

if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "No matching artifacts found for pattern: $ARTIFACT_GLOB"
  exit 1
fi

# Create symlink for gpg2 (required for rpm signing)
GPG_PATH=$(which gpg)
ln -sf "$GPG_PATH" /usr/bin/gpg2 2>/dev/null || true

echo "Found ${#FILES[@]} artifact(s) to sign"
for file in "${FILES[@]}"; do
  echo "Processing: $file"

  if [[ ! -f "$file" ]]; then
    continue
  fi

  # Skip signature and checksum files to prevent infinite loops
  if [[ "$file" =~ \.(asc|sha256)$ ]]; then
    continue
  fi

  ext="${file##*.}"

  # Sign .deb files
  if [[ "$ext" == "deb" ]]; then
    if command -v dpkg-sig &> /dev/null; then
      echo "Signing DEB with dpkg-sig"
      dpkg-sig --sign builder --gpg-options "--batch --pinentry-mode loopback --passphrase-file $GNUPGHOME/passphrase --quiet" "$file"
    else
      echo "ERROR: dpkg-sig not found"
      return 1
    fi
  fi

  # Sign .rpm files
  if [[ "$ext" == "rpm" ]]; then
    if command -v rpm &> /dev/null; then
      echo "Signing RPM with rpm --addsign"
      rpm --addsign "$file" 2>/dev/null
    else
      echo "ERROR: 'rpm' not found"
    fi
  fi

  # Always create detached GPG signature and SHA256 checksum for all files (including the ones just signed)
  gpg --detach-sign --no-tty --batch --yes --quiet \
    --passphrase-file "$GNUPGHOME/passphrase" \
    --output "$file.asc" "$file"

  # SHA256 checksum for original file
  shasum -a 256 "$file" > "$file.sha256"

  # SHA256 checksum for signature file
  shasum -a 256 "$file.asc" > "$file.asc.sha256"

  echo "Signed: $file"
  echo "  Signature: $file.asc"
  echo "  Checksum:  $file.sha256"
  echo "  Sig Checksum: $file.asc.sha256"
done
