#!/usr/bin/env bash
set -euo pipefail
# Find the git root directory
GIT_ROOT="$(git rev-parse --show-toplevel)"

# Define test directory
TEST_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts/test-artifacts"
BUILD_ARTIFACTS_DIR=${1:-$TEST_DIR/build-artifacts}

# Create test directory
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
mkdir -p "$BUILD_ARTIFACTS_DIR"

# Copy real test fixtures
echo "Copying test fixtures..."
if [[ -f "tests/nano-tiny_8.4-1_arm64.deb" ]]; then
    cp "tests/nano-tiny_8.4-1_arm64.deb" "$BUILD_ARTIFACTS_DIR/test-ubuntu22.04.deb"
    echo "  Copied nano-tiny_8.4-1_arm64.deb as test-ubuntu22.04.deb"
else
    echo "   nano-tiny_8.4-1_arm64.deb not found, creating mock"
    echo "test-deb-content" > "$BUILD_ARTIFACTS_DIR/test-ubuntu22.04.deb"
fi

if [[ -f "tests/test-1.0-2.noarch.rpm" ]]; then
    cp "tests/test-1.0-2.noarch.rpm" "$BUILD_ARTIFACTS_DIR/"
    echo "   Copied test-1.0-2.noarch.rpm"
else
    echo "   test-1.0-2.noarch.rpm not found, creating mock"
    echo "test-rpm-content" > "$BUILD_ARTIFACTS_DIR/test-1.0-2.noarch.rpm"
fi

cp tests/some/structure/Aerospike.Core.4.11.0.nupkg "$BUILD_ARTIFACTS_DIR/Aerospike.Core.4.11.0.nupkg"
echo "   Copied Aerospike.Core.4.11.0.nupkg"

# Create some additional test files
echo "test jar content" > "$BUILD_ARTIFACTS_DIR/test.jar"
echo "test zip content" > "$BUILD_ARTIFACTS_DIR/test.zip"
echo "test tar content" > "$BUILD_ARTIFACTS_DIR/test.tar.gz"
mkdir -p "$BUILD_ARTIFACTS_DIR/nested/dir"
echo "test-nested-dir-content" > "$BUILD_ARTIFACTS_DIR/nested/dir/test-nested-dir.txt"

# Create nested directory structure
mkdir -p "$BUILD_ARTIFACTS_DIR/nested/dir"
if [[ -f "tests/nano-tiny_8.4-1_arm64.deb" ]]; then
    cp "tests/nano-tiny_8.4-1_arm64.deb" "$BUILD_ARTIFACTS_DIR/nested/dir/test-debian12.deb"
    echo "   Copied nano-tiny_8.4-1_arm64.deb as nested test-debian12.deb"
else
    echo "test-nested-deb-content" > "$BUILD_ARTIFACTS_DIR/nested/dir/test-debian12.deb"
fi
if [[ -f "tests/test-1.0-2.noarch.rpm" ]]; then
    cp "tests/test-1.0-2.noarch.rpm" "$BUILD_ARTIFACTS_DIR/nested/dir/nested.rpm"
    echo "   Copied test-1.0-2.noarch.rpm as nested.rpm"
else
    echo "test-nested-rpm-content" > "$BUILD_ARTIFACTS_DIR/nested/dir/nested.rpm"
fi

echo "Test files created:"
find "$BUILD_ARTIFACTS_DIR" -type f | sort
