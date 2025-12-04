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
    echo "Error: tests/nano-tiny_8.4-1_arm64.deb not found. Cannot create mock DEB file." >&2
    exit 1
fi

if [[ -f "tests/test-1.0-2.noarch.rpm" ]]; then
    cp "tests/test-1.0-2.noarch.rpm" "$BUILD_ARTIFACTS_DIR/"
    echo "   Copied test-1.0-2.noarch.rpm"
else
    echo "Error: tests/test-1.0-2.noarch.rpm not found. Cannot create mock RPM file." >&2
    exit 1
fi
cp -v tests/some/structure/Aerospike.Client.8.0.2.nupkg "$BUILD_ARTIFACTS_DIR/Aerospike.Client.8.0.2.nupkg"

# Create some additional test files with valid formats
# Create a valid JAR file (JAR is a ZIP with META-INF/MANIFEST.MF)
mkdir -p "$BUILD_ARTIFACTS_DIR/temp-jar/META-INF"
echo "Manifest-Version: 1.0" >"$BUILD_ARTIFACTS_DIR/temp-jar/META-INF/MANIFEST.MF"
cd "$BUILD_ARTIFACTS_DIR/temp-jar" && zip -q -r "../test.jar" . && cd - >/dev/null
rm -rf "$BUILD_ARTIFACTS_DIR/temp-jar"

# Create a valid ZIP file
echo "test zip content" >"$BUILD_ARTIFACTS_DIR/temp-zip-content.txt"
cd "$BUILD_ARTIFACTS_DIR" && zip -q "test.zip" "temp-zip-content.txt" && cd - >/dev/null
rm -f "$BUILD_ARTIFACTS_DIR/temp-zip-content.txt"

# Create a valid TAR.GZ file
echo "test tar content" >"$BUILD_ARTIFACTS_DIR/temp-tar-content.txt"
cd "$BUILD_ARTIFACTS_DIR" && tar -czf "test.tar.gz" "temp-tar-content.txt" && cd - >/dev/null
rm -f "$BUILD_ARTIFACTS_DIR/temp-tar-content.txt"
mkdir -p "$BUILD_ARTIFACTS_DIR/nested/dir"
echo "test-nested-dir-content" >"$BUILD_ARTIFACTS_DIR/nested/dir/test-nested-dir.txt"

# Create nested directory structure
mkdir -p "$BUILD_ARTIFACTS_DIR/nested/dir"
if [[ -f "tests/nano-tiny_8.4-1_arm64.deb" ]]; then
    cp "tests/nano-tiny_8.4-1_arm64.deb" "$BUILD_ARTIFACTS_DIR/nested/dir/test-debian12.deb"
    echo "   Copied nano-tiny_8.4-1_arm64.deb as nested test-debian12.deb"
else
    echo "Error: tests/nano-tiny_8.4-1_arm64.deb not found. This file is required for nested test fixtures." >&2
    exit 1
fi
if [[ -f "tests/test-1.0-2.noarch.rpm" ]]; then
    cp "tests/test-1.0-2.noarch.rpm" "$BUILD_ARTIFACTS_DIR/nested/dir/nested.rpm"
    echo "   Copied test-1.0-2.noarch.rpm as nested.rpm"
else
    echo "Error: tests/test-1.0-2.noarch.rpm not found. This file is required for nested test fixtures." >&2
    exit 1
fi

echo "Test files created:"
find "$BUILD_ARTIFACTS_DIR" -type f | sort
