#!/usr/bin/env bash
set -euo pipefail
# Find the git root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_ROOT="$(git rev-parse --show-toplevel)"

# Define test directory
TEST_DIR="$GIT_ROOT/.github/workflows/sign-artifacts/test-artifacts"
SIGNED_ARTIFACTS_DIR="$TEST_DIR/signed-artifacts"
UNSIGNED_ARTIFACTS_DIR=${1:-$TEST_DIR/unsigned-artifacts}

# Cleanup function
cleanup() {
    echo "🧹 Cleaning up test artifacts..."
    rm -rf "$TEST_DIR"
    echo "✅ Cleanup complete"
}

# Set trap to cleanup on exit (success or error)
trap cleanup EXIT

echo "🧪 Testing sign-artifacts entrypoint script..."
echo "📁 Git root: $GIT_ROOT"
echo "📁 Script dir: $SCRIPT_DIR"

# Change to git root for consistent context
cd "$GIT_ROOT"

# Set environment variables consistent with test workflows
export HOME="/home/runner"
export GNUPGHOME="/home/runner/.gnupg"
export GPG_TTY="/dev/null"

# Create GPG directory
mkdir -p "$GNUPGHOME"
chmod 700 "$GNUPGHOME"

# Import test GPG key from fakesecrets.env
if [[ -f "fakesecrets.env" ]]; then
    source "fakesecrets.env"

    # Import keys
    echo "$GPG_SECRET_KEY" | gpg --import --batch --yes
    echo "$GPG_PUBLIC_KEY" | gpg --import --batch --yes

    # Get key fingerprint (first secret key)
    KEY_FP=$(gpg --list-secret-keys --with-colons | grep '^fpr:' | cut -d: -f10 | head -n1)

    # Configure GPG with heredoc
    cat > "$GNUPGHOME/gpg.conf" << EOF
default-key $KEY_FP
use-agent
pinentry-mode loopback
batch
no-tty
passphrase-file $GNUPGHOME/passphrase
EOF

    # Create passphrase file
    echo "$GPG_PASS" > "$GNUPGHOME/passphrase"
    chmod 600 "$GNUPGHOME/passphrase"

    # Configure RPM macros
    cat > "$HOME/.rpmmacros" << EOF
%_signature gpg
%_gpg_path $GNUPGHOME
%_gpg_name $KEY_FP
%_gpgbin /usr/bin/gpg2
%__gpg /usr/bin/gpg2
%__gpg_sign_cmd %{__gpg} --batch --pinentry-mode loopback --passphrase-file $GNUPGHOME/passphrase --no-armor --no-secmem-warning --no-tty -u "%{_gpg_name}" -sbo %{__signature_filename} %{__plaintext_filename}
EOF
    chmod 600 "$HOME/.rpmmacros"

    echo "✅ GPG setup complete"
else
    echo "❌ fakesecrets.env not found in git root: $GIT_ROOT"
    exit 1
fi

# # Create test directory and fixtures
# "$SCRIPT_DIR/create-test-fixtures.sh"

# Define expected test files explicitly
declare -a TEST_FILES=(
    "$UNSIGNED_ARTIFACTS_DIR/test.deb"
    "$UNSIGNED_ARTIFACTS_DIR/test-1.0-2.noarch.rpm"
    "$UNSIGNED_ARTIFACTS_DIR/test.jar"
    "$UNSIGNED_ARTIFACTS_DIR/test.zip"
    "$UNSIGNED_ARTIFACTS_DIR/nested/dir/nested.deb"
    "$UNSIGNED_ARTIFACTS_DIR/nested/dir/nested.rpm"
)

# Function to verify all expected files exist
verify_test_files() {
    local missing_files=()
    for file in "${TEST_FILES[@]}"; do
        if [[ ! -f "$file" ]]; then
            missing_files+=("$file")
        fi
    done
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        echo "❌ Missing expected test files:"
        printf '  %s\n' "${missing_files[@]}"
        exit 1
    fi
    echo "✅ All expected test files present"
}

# Function to verify files were signed
verify_files_signed() {
    local test_name="$1"
    local signed_count
    signed_count=$(find "$SIGNED_ARTIFACTS_DIR" -name "*.asc" | wc -l)
    if [[ $signed_count -eq 0 ]]; then
        echo "❌ ERROR: No files were signed in $test_name!"
        exit 1
    fi
    echo "✅ $test_name: $signed_count files signed"
}

# Test 1: Test with specific file types
echo ""
echo " Test 1: Signing specific file types"
find "$UNSIGNED_ARTIFACTS_DIR"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/entrypoint.sh" "$UNSIGNED_ARTIFACTS_DIR/**/*.{deb,rpm}" "$SIGNED_ARTIFACTS_DIR"

echo ""
echo "📋 Results for Test 1:"
for file in "$SIGNED_ARTIFACTS_DIR"/*.{deb,rpm}; do
    if [[ -f "$file" ]]; then
        echo "  ✅ $file"
        echo "    - Original: $(stat -c%s "$file" 2>/dev/null || echo "ERROR") bytes"
        echo "    - Signature: $(stat -c%s "$file.asc" 2>/dev/null || echo "MISSING") bytes"
        echo "    - Checksum: $(stat -c%s "$file.sha256" 2>/dev/null || echo "MISSING") bytes"
        echo "    - Sig Checksum: $(stat -c%s "$file.asc.sha256" 2>/dev/null || echo "MISSING") bytes"
    fi
done

# Test 2: Test with nested files
echo ""
echo " Test 2: Signing nested files"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/entrypoint.sh" "$UNSIGNED_ARTIFACTS_DIR/**/*.{deb,rpm}" "$SIGNED_ARTIFACTS_DIR"

echo ""
echo "📋 Results for Test 2:"
for file in "$SIGNED_ARTIFACTS_DIR"/**/*.{deb,rpm}; do
    if [[ -f "$file" ]]; then
        echo "  ✅ $file"
        echo "    - Original: $(stat -c%s "$file" 2>/dev/null || echo "ERROR") bytes"
        echo "    - Signature: $(stat -c%s "$file.asc" 2>/dev/null || echo "MISSING") bytes"
        echo "    - Checksum: $(stat -c%s "$file.sha256" 2>/dev/null || echo "MISSING") bytes"
        echo "    - Sig Checksum: $(stat -c%s "$file.asc.sha256" 2>/dev/null || echo "MISSING") bytes"
    fi
done

# Test 3: Test with all files
echo ""
echo " Test 3: Signing all files"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/entrypoint.sh" "$UNSIGNED_ARTIFACTS_DIR/**/*" "$SIGNED_ARTIFACTS_DIR"

echo ""
echo "📋 Results for Test 3:"
for file in "$SIGNED_ARTIFACTS_DIR"/**/*; do
    if [[ -f "$file" && ! "$file" =~ \.(asc|sha256)$ ]]; then
        echo "  ✅ $file"
        echo "    - Original: $(stat -c%s "$file" 2>/dev/null || echo "ERROR") bytes"
        echo "    - Signature: $(stat -c%s "$file.asc" 2>/dev/null || echo "MISSING") bytes"
        echo "    - Checksum: $(stat -c%s "$file.sha256" 2>/dev/null || echo "MISSING") bytes"
        echo "    - Sig Checksum: $(stat -c%s "$file.asc.sha256" 2>/dev/null || echo "MISSING") bytes"
    fi
done

# Test 4: Validate signatures
echo ""
echo " Test 4: Validating signatures"
for file in "$SIGNED_ARTIFACTS_DIR"/**/*.asc; do
    if [[ -f "$file" ]]; then
        original_file="${file%.asc}"
        if [[ -f "$original_file" ]]; then
            echo "  🔐 Validating signature for $original_file"
            if gpg --verify "$file" "$original_file" 2>/dev/null; then
                echo "    ✅ Signature is valid"
            else
                echo "    ❌ Signature validation failed"
            fi
        fi
    fi
done

# Test 5: Validate checksums
echo ""
echo " Test 5: Validating checksums"
for file in "$SIGNED_ARTIFACTS_DIR"/**/*.sha256; do
    if [[ -f "$file" ]]; then
        original_file="${file%.sha256}"
        if [[ -f "$original_file" ]]; then
            echo "   Validating checksum for $original_file"
            if shasum -a 256 -c "$file" 2>/dev/null; then
                echo "    ✅ Checksum is valid"
            else
                echo "    ❌ Checksum validation failed"
            fi
        fi
    fi
done
# Summary
echo ""
echo "📊 Test Summary:"
echo "  - Test files created: $(find "$SIGNED_ARTIFACTS_DIR" -type f ! -name "*.asc" ! -name "*.sha256" | wc -l)"
echo "  - Signatures created: $(find "$SIGNED_ARTIFACTS_DIR" -name "*.asc" | wc -l)"
echo "  - Checksums created: $(find "$SIGNED_ARTIFACTS_DIR" -name "*.sha256" | wc -l)"
echo "  - Total files: $(find "$SIGNED_ARTIFACTS_DIR" -type f | wc -l)"

echo ""
echo "🎉 Entrypoint script testing completed!"
