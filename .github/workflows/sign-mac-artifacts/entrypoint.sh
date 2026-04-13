#!/usr/bin/env bash
set -euo pipefail

# --- Constants ---
KEYCHAIN_NAME="sign-mac-build.keychain"
KEYCHAIN_PASSWORD=""
NOTARIZE="true"
DRY_RUN="false"
SOURCE_DIR=""
TARGET_DIR=""
ARTIFACT_GLOB="**/*"

# --- Error handling ---
handle_error() {
    local line_no=$1
    local command=$2
    echo "ERROR: Command '$command' failed at line $line_no" >&2
    exit 1
}
trap 'handle_error ${LINENO} "$BASH_COMMAND"' ERR

# --- Dry-run wrapper ---
run() {
    if [[ $DRY_RUN == "true" ]]; then
        echo "[DRY-RUN] $*"
        return 0
    fi
    "$@"
}

# --- Usage ---
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Sign and optionally notarize macOS artifacts (Mach-O binaries, .pkg, .dmg).

Options:
  --source-dir DIR       Directory containing unsigned artifacts (required)
  --target-dir DIR       Output directory for signed artifacts (required)
  --artifact-glob GLOB   Glob pattern for files to sign (default: **/*).
                         Controls signing scope only; the full tree is always copied.
  --notarize             Enable notarization after signing (default)
  --no-notarize          Disable notarization
  --dry-run              Print commands without executing
  --help                 Show this help message

Environment variables (required):
  APPLE_APPLICATION_CERT   Base64-encoded .p12 for codesign
  SIGNING_IDENTITY         codesign identity string

Environment variables (optional):
  APPLE_INSTALLER_CERT         Base64-encoded .p12 for productsign
  APPLE_CERT_PASSWORD          Password for .p12 certificate import (if cert is encrypted)
  APPLE_NOTARIZATION_PASSWORD  App-specific password for notarization
  INSTALLER_IDENTITY           productsign identity string
  APPLE_ID                     Apple ID email (required for notarization)
  APPLE_TEAM_ID                Developer Team ID (required for notarization)

Examples:
  # Sign all files
  entrypoint.sh --source-dir unsigned-artifacts --target-dir signed-output

  # Sign only .pkg files
  entrypoint.sh --source-dir unsigned-artifacts --target-dir signed-output --artifact-glob '*.pkg'

  # Dry run
  entrypoint.sh --source-dir unsigned-artifacts --target-dir signed-output --dry-run
EOF
}

# --- Argument parsing ---
while [[ $# -gt 0 ]]; do
    case "$1" in
    --source-dir)
        SOURCE_DIR="$2"
        shift 2
        ;;
    --target-dir)
        TARGET_DIR="$2"
        shift 2
        ;;
    --artifact-glob)
        ARTIFACT_GLOB="$2"
        shift 2
        ;;
    --notarize)
        NOTARIZE="true"
        shift
        ;;
    --no-notarize)
        NOTARIZE="false"
        shift
        ;;
    --dry-run)
        DRY_RUN="true"
        shift
        ;;
    --help)
        usage
        exit 0
        ;;
    *)
        echo "Unknown option: $1" >&2
        usage >&2
        exit 1
        ;;
    esac
done

# --- Validation ---
if [[ -z $SOURCE_DIR ]]; then
    echo "ERROR: --source-dir is required" >&2
    exit 1
fi
if [[ -z $TARGET_DIR ]]; then
    echo "ERROR: --target-dir is required" >&2
    exit 1
fi
if [[ ! -d $SOURCE_DIR ]]; then
    echo "ERROR: Source directory does not exist: $SOURCE_DIR" >&2
    exit 1
fi
if [[ -z ${SIGNING_IDENTITY-} ]]; then
    echo "ERROR: SIGNING_IDENTITY environment variable is required" >&2
    exit 1
fi
if [[ $DRY_RUN != "true" ]]; then
    if [[ -z ${APPLE_APPLICATION_CERT-} ]]; then
        echo "ERROR: APPLE_APPLICATION_CERT environment variable is required" >&2
        exit 1
    fi
    if [[ $NOTARIZE == "true" ]]; then
        for var in APPLE_ID APPLE_NOTARIZATION_PASSWORD APPLE_TEAM_ID; do
            if [[ -z ${!var-} ]]; then
                echo "ERROR: $var is required when notarization is enabled" >&2
                exit 1
            fi
        done
    fi
fi

# --- Keychain management ---
import_p12_via_pem() {
    local b64_p12="$1"
    local password="${2-}"
    local p12 cert_pem key_pem
    p12=$(mktemp)
    cert_pem=$(mktemp)
    key_pem=$(mktemp)

    printf '%s' "$b64_p12" | base64 -d >"$p12"
    echo "  Importing cert: $(wc -c <"$p12") bytes"

    openssl pkcs12 -in "$p12" -clcerts -nokeys -passin "pass:${password}" -out "$cert_pem"
    openssl pkcs12 -in "$p12" -nocerts -nodes -passin "pass:${password}" -out "$key_pem"

    run security import "$cert_pem" -k "$KEYCHAIN_NAME" -A
    run security import "$key_pem" -k "$KEYCHAIN_NAME" -A

    rm -f "$p12" "$cert_pem" "$key_pem"
}

setup_keychain() {
    echo "==> Setting up temporary keychain"
    KEYCHAIN_PASSWORD=$(openssl rand -base64 32)

    run security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
    run security default-keychain -s "$KEYCHAIN_NAME"
    run security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
    run security set-keychain-settings "$KEYCHAIN_NAME"

    import_p12_via_pem "$APPLE_APPLICATION_CERT" "${APPLE_CERT_PASSWORD-}"

    if [[ -n ${APPLE_INSTALLER_CERT-} ]]; then
        import_p12_via_pem "$APPLE_INSTALLER_CERT" "${APPLE_CERT_PASSWORD-}"
    fi

    run security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
    echo "==> Keychain setup complete"
}

cleanup_keychain() {
    echo "==> Cleaning up keychain"
    security delete-keychain "$KEYCHAIN_NAME" 2>/dev/null || true
}

# --- File type detection ---
is_macho() {
    local file="$1"
    if [[ $DRY_RUN == "true" ]]; then
        # In dry-run, treat extensionless files as Mach-O for demonstration
        [[ ! $file =~ \. ]] && return 0
        return 1
    fi
    file "$file" | grep -q "Mach-O"
}

# --- Signing functions ---
sign_binary() {
    local file="$1"
    echo "  Signing binary: $file"
    run codesign --deep --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" "$file"
}

verify_codesign() {
    local file="$1"
    echo "  Verifying codesign: $file"
    run codesign --verify --deep --strict "$file"
}

sign_package() {
    local file="$1"
    if [[ -z ${INSTALLER_IDENTITY-} ]]; then
        echo "ERROR: INSTALLER_IDENTITY is required to sign .pkg files" >&2
        exit 1
    fi
    echo "  Signing package: $file"
    local signed_file="${file}.signed"
    run productsign --sign "$INSTALLER_IDENTITY" "$file" "$signed_file"
    if [[ $DRY_RUN != "true" ]]; then
        mv "$signed_file" "$file"
    fi
}

verify_package() {
    local file="$1"
    echo "  Verifying package signature: $file"
    run pkgutil --check-signature "$file"
}

sign_dmg() {
    local file="$1"
    echo "  Signing DMG: $file"
    run codesign --force --options runtime --timestamp \
        --sign "$SIGNING_IDENTITY" "$file"
}

# --- Notarization ---
notarize_and_staple() {
    local file="$1"
    if [[ $NOTARIZE != "true" ]]; then
        return 0
    fi
    echo "  Submitting for notarization: $file"

    if [[ $DRY_RUN == "true" ]]; then
        echo "[DRY-RUN] xcrun notarytool submit $file --apple-id *** --password *** --team-id *** --wait"
        echo "[DRY-RUN] xcrun stapler staple $file"
        return 0
    fi

    local submit_output
    submit_output=$(xcrun notarytool submit "$file" \
        --apple-id "$APPLE_ID" \
        --password "$APPLE_NOTARIZATION_PASSWORD" \
        --team-id "$APPLE_TEAM_ID" \
        --wait \
        --output-format json 2>&1) || {
        echo "ERROR: Notarization failed for $file" >&2
        echo "$submit_output" >&2

        # Try to extract submission ID and fetch the log for diagnostics
        local submission_id
        submission_id=$(echo "$submit_output" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
        if [[ -n $submission_id ]]; then
            echo "==> Fetching notarization log for submission $submission_id" >&2
            xcrun notarytool log "$submission_id" \
                --apple-id "$APPLE_ID" \
                --password "$APPLE_NOTARIZATION_PASSWORD" \
                --team-id "$APPLE_TEAM_ID" >&2 || true
        fi
        exit 1
    }

    echo "  Notarization succeeded, stapling ticket"
    local attempt
    for attempt in 1 2 3 4 5 6; do
        if xcrun stapler staple "$file"; then
            return 0
        fi
        echo "  Staple attempt $attempt/6 failed, retrying in 30s..." >&2
        sleep 30
    done
    echo "ERROR: stapler staple failed after 6 attempts (3 min) for $file" >&2
    exit 1
}

verify_staple() {
    local file="$1"
    echo "  Verifying staple: $file"
    run xcrun stapler validate "$file"
}

# --- Glob matching ---
matches_glob() {
    local file="$1"
    local pattern="$2"

    if [[ $pattern == "**/*" ]]; then
        return 0
    fi

    local filename
    filename=$(basename "$file")

    # Use bash pattern matching for simple globs
    # shellcheck disable=SC2254
    case "$filename" in
    $pattern) return 0 ;;
    esac

    # Also try matching against relative path
    # shellcheck disable=SC2254
    case "$file" in
    $pattern) return 0 ;;
    esac

    return 1
}

# --- Main ---
main() {
    echo "============================================"
    echo "Mac Artifact Signing"
    echo "============================================"
    echo "Source directory: $SOURCE_DIR"
    echo "Target directory: $TARGET_DIR"
    echo "Artifact glob:   $ARTIFACT_GLOB"
    echo "Notarize:        $NOTARIZE"
    echo "Dry run:         $DRY_RUN"
    echo "Signing identity: $SIGNING_IDENTITY"
    echo "Installer identity: ${INSTALLER_IDENTITY:-<not set>}"
    echo "============================================"

    # Copy the full artifact tree (preserving all non-Mac files)
    echo "==> Copying full artifact tree to $TARGET_DIR"
    mkdir -p "$TARGET_DIR"
    if [[ -n "$(ls -A "$SOURCE_DIR" 2>/dev/null)" ]]; then
        cp -R "$SOURCE_DIR"/* "$TARGET_DIR/"
    else
        echo "WARNING: Source directory is empty: $SOURCE_DIR" >&2
        return 0
    fi

    echo "==> Artifact tree contents:"
    find "$TARGET_DIR" -type f | sort

    # Set up keychain for signing (skipped in dry-run since certs may not be available)
    if [[ $DRY_RUN != "true" ]]; then
        setup_keychain
        trap cleanup_keychain EXIT
    else
        echo "==> [DRY-RUN] Skipping keychain setup"
    fi

    # Process files
    local signed_count=0
    local skipped_count=0

    echo "==> Processing artifacts for signing"
    while IFS= read -r file; do
        # Skip signature and checksum files
        if [[ $file =~ \.(asc|sha256)$ ]]; then
            continue
        fi

        # Check if file matches the signing glob
        local relative_path="${file#"$TARGET_DIR"/}"
        if ! matches_glob "$relative_path" "$ARTIFACT_GLOB"; then
            ((skipped_count++)) || true
            continue
        fi

        local ext="${file##*.}"
        case "$ext" in
        pkg)
            echo ""
            echo "--- Processing .pkg: $relative_path ---"
            sign_package "$file"
            verify_package "$file"
            notarize_and_staple "$file"
            if [[ $NOTARIZE == "true" ]]; then
                verify_staple "$file"
            fi
            ((signed_count++)) || true
            ;;
        dmg)
            echo ""
            echo "--- Processing .dmg: $relative_path ---"
            sign_dmg "$file"
            verify_codesign "$file"
            notarize_and_staple "$file"
            if [[ $NOTARIZE == "true" ]]; then
                verify_staple "$file"
            fi
            ((signed_count++)) || true
            ;;
        *)
            if is_macho "$file"; then
                echo ""
                echo "--- Processing Mach-O binary: $relative_path ---"
                sign_binary "$file"
                verify_codesign "$file"
                ((signed_count++)) || true
            fi
            ;;
        esac
    done < <(find "$TARGET_DIR" -type f | sort)

    echo ""
    echo "============================================"
    echo "Signing complete"
    echo "  Files signed:  $signed_count"
    echo "  Files skipped: $skipped_count (not matching glob or not a signable type)"
    echo "============================================"
}

main
