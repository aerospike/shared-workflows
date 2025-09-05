#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_GLOB="${1:-}"
TARGET_DIR="${2:-}"
MAVEN_COMPATIBLE="${3:-true}"

# Set environment variables consistent with test workflows
export HOME="/home/runner"
export GNUPGHOME="/home/runner/.gnupg"
export GPG_TTY="/dev/null"

echo "Expanding glob pattern: $ARTIFACT_GLOB"
echo "Maven compatible mode: $MAVEN_COMPATIBLE"
shopt -s globstar nullglob #  Necessary options for globbing

# Create symlink for gpg2 (required for some Java build tools)
GPG_PATH=$(which gpg)
ln -sf "$GPG_PATH" /usr/bin/gpg2 2>/dev/null || true

# Validate the glob pattern to ensure it is safe
if [[ -z "$ARTIFACT_GLOB" || "$ARTIFACT_GLOB" =~ [^a-zA-Z0-9._*/?{},-] ]]; then
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
    if [[ -f "$file" ]]; then
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
  if [[ "$file" =~ \.(asc|sha1|sha256|md5)$ ]]; then
    continue
  fi

  ext="${file##*.}"
  
  # Java-specific file detection
  is_java_artifact=false
  if [[ "$ext" == "jar" || "$ext" == "war" || "$ext" == "ear" || "$ext" == "pom" || "$ext" == "aar" ]]; then
    is_java_artifact=true
    echo "Detected Java artifact: $file"
  fi

  # Always create detached GPG signature
  gpg --detach-sign --no-tty --batch --yes --quiet \
    --passphrase-file "$GNUPGHOME/passphrase" \
    --output "$file.asc" "$file"

  # Create checksums based on Maven compatibility mode
  if [[ "$MAVEN_COMPATIBLE" == "true" ]]; then
    # Maven Central requires SHA1 and MD5 checksums
    sha1sum "$file" | cut -d' ' -f1 > "$file.sha1"
    md5sum "$file" | cut -d' ' -f1 > "$file.md5"
    
    # Also create checksums for signature files
    sha1sum "$file.asc" | cut -d' ' -f1 > "$file.asc.sha1"
    md5sum "$file.asc" | cut -d' ' -f1 > "$file.asc.md5"
    
    echo "Created Maven-compatible checksums:"
    echo "  SHA1: $file.sha1"
    echo "  MD5:  $file.md5"
    echo "  Sig SHA1: $file.asc.sha1"
    echo "  Sig MD5:  $file.asc.md5"
  else
    # Standard SHA256 checksums (like the original sign-artifacts)
    shasum -a 256 "$file" > "$file.sha256"
    shasum -a 256 "$file.asc" > "$file.asc.sha256"
    
    echo "Created standard checksums:"
    echo "  SHA256: $file.sha256"
    echo "  Sig SHA256: $file.asc.sha256"
  fi

  echo "Signed: $file"
  echo "  Signature: $file.asc"
  
  # Special handling for POM files in Java projects
  if [[ "$ext" == "pom" && "$is_java_artifact" == "true" ]]; then
    echo "  POM file signed for Maven Central compatibility"
  fi
done