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

# --- Helm chart helpers ---
# Helm charts use a native provenance file (.prov) as their canonical signature
# instead of a detached .asc. The .prov is a GPG clearsigned message containing
# the Chart.yaml metadata plus a sha256 of the .tgz, exactly what
# `helm package --sign` produces.

# Extract Chart.yaml content from a packaged helm chart .tgz.
# Helm packages have <chart-name>/Chart.yaml at the root of the tarball.
_extract_helm_chart_yaml() {
    local file="$1"
    local chart_path
    chart_path=$(tar -tzf "$file" 2>/dev/null | grep -E '^[^/]+/Chart\.yaml$' | head -n1) || return 1
    [ -z "$chart_path" ] && return 1
    tar -xOzf "$file" "$chart_path" 2>/dev/null
}

# Returns 0 if the given .tgz/.tar.gz is a packaged helm chart.
is_helm_chart() {
    local file="$1"
    case "$file" in
    *.tgz | *.tar.gz) ;;
    *) return 1 ;;
    esac
    local chart_yaml
    chart_yaml=$(_extract_helm_chart_yaml "$file") || return 1
    grep -qE '^apiVersion:[[:space:]]*v[12]\b' <<<"$chart_yaml" || return 1
    grep -qE '^name:[[:space:]]*[^[:space:]]' <<<"$chart_yaml" || return 1
    grep -qE '^version:[[:space:]]*[^[:space:]]' <<<"$chart_yaml" || return 1
}

# Produce a helm-native provenance file (<file>.prov) for a packaged chart.
# The .prov is a GPG clearsigned YAML containing the Chart.yaml content plus a
# files: section with sha256 of the .tgz. This matches the format helm itself
# generates for `helm package --sign` and is verifiable by `helm verify`.
sign_helm_chart() {
    local file="$1"
    local chart_yaml
    if ! chart_yaml=$(_extract_helm_chart_yaml "$file"); then
        echo "ERROR: failed to extract Chart.yaml from $file" >&2
        return 1
    fi
    local sha256
    sha256=$(sha256sum "$file" | awk '{print $1}')
    local filename
    filename=$(basename "$file")

    local payload_file
    payload_file=$(mktemp)
    {
        printf '%s\n' "$chart_yaml"
        printf '...\nfiles:\n  %s: sha256:%s\n' "$filename" "$sha256"
    } >"$payload_file"

    gpg --clearsign --no-tty --batch --yes --quiet \
        --passphrase-file "$GNUPGHOME/passphrase" \
        --output "$file.prov" \
        "$payload_file"

    rm -f "$payload_file"
    echo "  Provenance: $file.prov"
}

# Process all files in the target directory
echo "Processing all files in target directory: $TARGET_DIR"
echo "Target directory contents:"
ls -la "$TARGET_DIR"
find "$TARGET_DIR" -type f | while read -r file; do
    echo "Processing: $file"

    # Skip signature, provenance, and checksum files to prevent infinite loops
    if [[ $file =~ \.(asc|prov|sha256)$ ]]; then
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

    # Helm chart .tgz: produce a helm-native .prov instead of a detached .asc.
    if is_helm_chart "$file"; then
        echo "Signing Helm chart with provenance (.prov)"
        sign_helm_chart "$file"
        echo "Signed: $file"
        continue
    fi

    # Always create detached GPG signature for all other files
    gpg --detach-sign --no-tty --batch --yes --quiet \
        --passphrase-file "$GNUPGHOME/passphrase" \
        --output "$file.asc" "$file"

    echo "Signed: $file"
    echo "  Signature: $file.asc"
done
