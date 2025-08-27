#!/usr/bin/env bash
set -euo pipefail

# Find the git root directory
GIT_ROOT="$(git rev-parse --show-toplevel)"

# Define test directory
TEST_DIR="$GIT_ROOT/.github/workflows/sign-artifacts/test-artifacts"
UNSIGNED_ARTIFACTS_DIR=${1:-$TEST_DIR/unsigned-artifacts}

# Create test directory
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
mkdir -p "$UNSIGNED_ARTIFACTS_DIR"

# Copy real test fixtures
echo "📝 Copying test fixtures..."
if [[ -f "tests/test.deb" ]]; then
    cp "tests/test.deb" "$UNSIGNED_ARTIFACTS_DIR/"
    echo "  ✅ Copied test.deb"
else
    echo "  ❌ test.deb not found"
fi

if [[ -f "tests/test-1.0-2.noarch.rpm" ]]; then
    cp "tests/test-1.0-2.noarch.rpm" "$UNSIGNED_ARTIFACTS_DIR/"
    echo "  ✅ Copied test-1.0-2.noarch.rpm"
else
    echo "  ❌ test-1.0-2.noarch.rpm not found"
fi

# Create some additional test files
echo "test jar content" > "$UNSIGNED_ARTIFACTS_DIR/test.jar"
echo "test zip content" > "$UNSIGNED_ARTIFACTS_DIR/test.zip"

# Create nested directory structure
mkdir -p "$UNSIGNED_ARTIFACTS_DIR/nested/dir"
if [[ -f "tests/test.deb" ]]; then
    cp "tests/test.deb" "$UNSIGNED_ARTIFACTS_DIR/nested/dir/nested.deb"
fi
if [[ -f "tests/test-1.0-2.noarch.rpm" ]]; then
    cp "tests/test-1.0-2.noarch.rpm" "$UNSIGNED_ARTIFACTS_DIR/nested/dir/nested.rpm"
fi

echo "�� Test files created:"
find "$UNSIGNED_ARTIFACTS_DIR" -type f | sort
