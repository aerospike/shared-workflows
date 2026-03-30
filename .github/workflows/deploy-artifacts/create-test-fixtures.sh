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
if [[ -f "tests/some/structure/Aerospike.Client.8.0.2.nupkg" ]]; then
    cp "tests/some/structure/Aerospike.Client.8.0.2.nupkg" "$BUILD_ARTIFACTS_DIR/Aerospike.Client.8.0.2.nupkg"
    echo "   Copied Aerospike.Client.8.0.2.nupkg"
else
    echo "Error: tests/some/structure/Aerospike.Client.8.0.2.nupkg not found. Cannot create mock NuGet package." >&2
    exit 1
fi
if [[ -f "tests/test-1.0-2.noarch.rpm" ]]; then
    cp "tests/test-1.0-2.noarch.rpm" "$BUILD_ARTIFACTS_DIR/"
    echo "   Copied test-1.0-2.noarch.rpm"
else
    echo "Error: tests/test-1.0-2.noarch.rpm not found. Cannot create mock RPM file." >&2
    exit 1
fi
if [[ -f "tests/test-all-arch_1.0.0-1ubuntu22.04_all.deb" ]]; then
    cp "tests/test-all-arch_1.0.0-1ubuntu22.04_all.deb" "$BUILD_ARTIFACTS_DIR/"
    echo "   Copied test-all-arch_1.0.0-1ubuntu22.04_all.deb (Architecture: all)"
else
    echo "Error: tests/test-all-arch_1.0.0-1ubuntu22.04_all.deb not found." >&2
    exit 1
fi

# Create NuGet package in subdirectory to match real-world scenario
mkdir -p "$BUILD_ARTIFACTS_DIR/nuget"
if [[ -f "tests/some/structure/Aerospike.Client.8.0.2.nupkg" ]]; then
    cp "tests/some/structure/Aerospike.Client.8.0.2.nupkg" "$BUILD_ARTIFACTS_DIR/nuget/Aerospike.HelloWorld.1.0.0.nupkg"
    echo "   Copied Aerospike.Client.8.0.2.nupkg as nuget/Aerospike.HelloWorld.1.0.0.nupkg"
    # Create an snupkg (symbol package) alongside the nupkg
    cp "tests/some/structure/Aerospike.Client.8.0.2.nupkg" "$BUILD_ARTIFACTS_DIR/nuget/Aerospike.HelloWorld.1.0.0.snupkg"
    echo "   Copied Aerospike.Client.8.0.2.nupkg as nuget/Aerospike.HelloWorld.1.0.0.snupkg"
else
    echo "Error: tests/some/structure/Aerospike.Client.8.0.2.nupkg not found. Cannot create nested NuGet package." >&2
    exit 1
fi

# Create a valid npm package .tgz (npm pack format: package/ prefix with package.json)
mkdir -p "$BUILD_ARTIFACTS_DIR/temp-npm/package"
cat >"$BUILD_ARTIFACTS_DIR/temp-npm/package/package.json" <<'PKGJSON'
{"name":"@aerospike/test-package","version":"1.0.0","description":"test npm package"}
PKGJSON
echo "module.exports = {};" >"$BUILD_ARTIFACTS_DIR/temp-npm/package/index.js"
cd "$BUILD_ARTIFACTS_DIR/temp-npm" && tar -czf "../aerospike-test-package-1.0.0.tgz" package/ && cd - >/dev/null
rm -rf "$BUILD_ARTIFACTS_DIR/temp-npm"
echo "  Created aerospike-test-package-1.0.0.tgz (npm package)"

# Create a valid unscoped npm package .tgz
mkdir -p "$BUILD_ARTIFACTS_DIR/temp-npm-unscoped/package"
cat >"$BUILD_ARTIFACTS_DIR/temp-npm-unscoped/package/package.json" <<'PKGJSON'
{"name":"aerospike","version":"6.0.0","description":"test unscoped npm package"}
PKGJSON
echo "module.exports = {};" >"$BUILD_ARTIFACTS_DIR/temp-npm-unscoped/package/index.js"
cd "$BUILD_ARTIFACTS_DIR/temp-npm-unscoped" && tar -czf "../aerospike-6.0.0.tgz" package/ && cd - >/dev/null
rm -rf "$BUILD_ARTIFACTS_DIR/temp-npm-unscoped"
echo "  Created aerospike-6.0.0.tgz (unscoped npm package)"

# Create a non-npm .tgz (should route to generic, not npm)
echo "not an npm package" >"$BUILD_ARTIFACTS_DIR/temp-generic-tgz-content.txt"
cd "$BUILD_ARTIFACTS_DIR" && tar -czf "generic-archive.tgz" "temp-generic-tgz-content.txt" && cd - >/dev/null
rm -f "$BUILD_ARTIFACTS_DIR/temp-generic-tgz-content.txt"
echo "  Created generic-archive.tgz (non-npm tarball)"

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
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/test.zip.asc"

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

# Create .asc companion files (simulated detached GPG signatures)
# In production, the sign stage creates these alongside every artifact
echo "Creating .asc companion files..."
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/test.jar.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/test-ubuntu22.04.deb.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/test-1.0-2.noarch.rpm.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/test-all-arch_1.0.0-1ubuntu22.04_all.deb.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/Aerospike.Client.8.0.2.nupkg.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/nuget/Aerospike.HelloWorld.1.0.0.nupkg.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/nuget/Aerospike.HelloWorld.1.0.0.snupkg.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/nested/dir/test-debian12.deb.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/nested/dir/nested.rpm.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/aerospike-test-package-1.0.0.tgz.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/aerospike-6.0.0.tgz.asc"

# Create unsigned-artifacts/ prefix to simulate sign stage output
# The sign stage uses cp --parents which creates: signed-artifacts/unsigned-artifacts/...
# Deploy receives this as: build-artifacts/unsigned-artifacts/...
mkdir -p "$BUILD_ARTIFACTS_DIR/unsigned-artifacts/net8.0"
echo "generic-content" >"$BUILD_ARTIFACTS_DIR/unsigned-artifacts/net8.0/app.dll"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/unsigned-artifacts/net8.0/app.dll.asc"

echo "Test files created:"
find "$BUILD_ARTIFACTS_DIR" -type f | sort
