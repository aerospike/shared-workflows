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
    # Rename to include dist tag so get_rpm_metadata extracts a valid distribution.
    # The source RPM lacks a dist segment; real RPMs use patterns like name-ver-rel.el9.arch.rpm.
    cp "tests/test-1.0-2.noarch.rpm" "$BUILD_ARTIFACTS_DIR/test-1.0-2.el9.noarch.rpm"
    echo "   Copied test-1.0-2.noarch.rpm as test-1.0-2.el9.noarch.rpm"
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

# Create a valid npm package with .tar.gz extension (less common but valid)
mkdir -p "$BUILD_ARTIFACTS_DIR/temp-npm-targz/package"
cat >"$BUILD_ARTIFACTS_DIR/temp-npm-targz/package/package.json" <<'PKGJSON'
{"name":"@aerospike/targz-package","version":"3.0.0","description":"npm package with .tar.gz extension"}
PKGJSON
echo "module.exports = {};" >"$BUILD_ARTIFACTS_DIR/temp-npm-targz/package/index.js"
cd "$BUILD_ARTIFACTS_DIR/temp-npm-targz" && tar -czf "../aerospike-targz-package-3.0.0.tar.gz" package/ && cd - >/dev/null
rm -rf "$BUILD_ARTIFACTS_DIR/temp-npm-targz"
echo "  Created aerospike-targz-package-3.0.0.tar.gz (npm package with .tar.gz extension)"

# Create a non-npm .tgz (should route to generic, not npm)
echo "not an npm package" >"$BUILD_ARTIFACTS_DIR/temp-generic-tgz-content.txt"
cd "$BUILD_ARTIFACTS_DIR" && tar -czf "generic-archive.tgz" "temp-generic-tgz-content.txt" && cd - >/dev/null
rm -f "$BUILD_ARTIFACTS_DIR/temp-generic-tgz-content.txt"
echo "  Created generic-archive.tgz (non-npm tarball)"

# Create a valid Python wheel (.whl) file
# Wheel is a ZIP with a .dist-info/METADATA file
mkdir -p "$BUILD_ARTIFACTS_DIR/temp-whl/aerospike_hello-1.0.0.dist-info"
cat >"$BUILD_ARTIFACTS_DIR/temp-whl/aerospike_hello-1.0.0.dist-info/METADATA" <<'METADATA'
Metadata-Version: 2.1
Name: aerospike-hello
Version: 1.0.0
Summary: Test Python package for shared-workflows CI/CD
METADATA
cat >"$BUILD_ARTIFACTS_DIR/temp-whl/aerospike_hello-1.0.0.dist-info/WHEEL" <<'WHEEL'
Wheel-Version: 1.0
Generator: test
Root-Is-Purelib: true
Tag: py3-none-any
WHEEL
mkdir -p "$BUILD_ARTIFACTS_DIR/temp-whl/aerospike_hello"
echo 'print("Hello from aerospike-hello!")' >"$BUILD_ARTIFACTS_DIR/temp-whl/aerospike_hello/__init__.py"
cd "$BUILD_ARTIFACTS_DIR/temp-whl" && zip -q -r "../aerospike_hello-1.0.0-py3-none-any.whl" . && cd - >/dev/null
rm -rf "$BUILD_ARTIFACTS_DIR/temp-whl"
echo "  Created aerospike_hello-1.0.0-py3-none-any.whl (Python wheel)"

# Create a valid Python sdist (.tar.gz) with PKG-INFO
mkdir -p "$BUILD_ARTIFACTS_DIR/temp-sdist/aerospike-hello-1.0.0"
cat >"$BUILD_ARTIFACTS_DIR/temp-sdist/aerospike-hello-1.0.0/PKG-INFO" <<'PKGINFO'
Metadata-Version: 2.1
Name: aerospike-hello
Version: 1.0.0
Summary: Test Python package for shared-workflows CI/CD
PKGINFO
mkdir -p "$BUILD_ARTIFACTS_DIR/temp-sdist/aerospike-hello-1.0.0/src/aerospike_hello"
echo 'print("Hello!")' >"$BUILD_ARTIFACTS_DIR/temp-sdist/aerospike-hello-1.0.0/src/aerospike_hello/__init__.py"
cd "$BUILD_ARTIFACTS_DIR/temp-sdist" && tar -czf "../aerospike-hello-1.0.0.tar.gz" "aerospike-hello-1.0.0/" && cd - >/dev/null
rm -rf "$BUILD_ARTIFACTS_DIR/temp-sdist"
echo "  Created aerospike-hello-1.0.0.tar.gz (Python sdist)"

# Create a valid Python sdist with .tgz extension (less common but valid)
mkdir -p "$BUILD_ARTIFACTS_DIR/temp-sdist-tgz/aerospike-utils-2.0.0"
cat >"$BUILD_ARTIFACTS_DIR/temp-sdist-tgz/aerospike-utils-2.0.0/PKG-INFO" <<'PKGINFO'
Metadata-Version: 2.1
Name: aerospike-utils
Version: 2.0.0
Summary: Test Python package with .tgz extension
PKGINFO
mkdir -p "$BUILD_ARTIFACTS_DIR/temp-sdist-tgz/aerospike-utils-2.0.0/src/aerospike_utils"
echo 'print("Hello!")' >"$BUILD_ARTIFACTS_DIR/temp-sdist-tgz/aerospike-utils-2.0.0/src/aerospike_utils/__init__.py"
cd "$BUILD_ARTIFACTS_DIR/temp-sdist-tgz" && tar -czf "../aerospike-utils-2.0.0.tgz" "aerospike-utils-2.0.0/" && cd - >/dev/null
rm -rf "$BUILD_ARTIFACTS_DIR/temp-sdist-tgz"
echo "  Created aerospike-utils-2.0.0.tgz (Python sdist with .tgz extension)"

# Create a valid Go module zip archive
# Go module zips have files prefixed with module@version/
mkdir -p "$BUILD_ARTIFACTS_DIR/temp-gomod/github.com/aerospike/aeromod@v1.2.3"
cat >"$BUILD_ARTIFACTS_DIR/temp-gomod/github.com/aerospike/aeromod@v1.2.3/go.mod" <<'GOMOD'
module github.com/aerospike/aeromod

go 1.21
GOMOD
echo 'package aeromod' >"$BUILD_ARTIFACTS_DIR/temp-gomod/github.com/aerospike/aeromod@v1.2.3/aeromod.go"
cd "$BUILD_ARTIFACTS_DIR/temp-gomod" && zip -q -r "../aeromod-v1.2.3.zip" "github.com/" && cd - >/dev/null
rm -rf "$BUILD_ARTIFACTS_DIR/temp-gomod"
echo "  Created aeromod-v1.2.3.zip (Go module)"

# Create a valid packaged Helm chart .tgz with Chart.yaml and a fake .prov sidecar.
# Real chart packages have a single top-level dir named after the chart with Chart.yaml at root.
mkdir -p "$BUILD_ARTIFACTS_DIR/temp-helm/aerospike-hello"
cat >"$BUILD_ARTIFACTS_DIR/temp-helm/aerospike-hello/Chart.yaml" <<'CHART'
apiVersion: v2
name: aerospike-hello
description: A test helm chart
type: application
version: 0.4.2
appVersion: "0.4.2"
CHART
cd "$BUILD_ARTIFACTS_DIR/temp-helm" && tar -czf "../aerospike-hello-0.4.2.tgz" "aerospike-hello/" && cd - >/dev/null
rm -rf "$BUILD_ARTIFACTS_DIR/temp-helm"
echo "FAKE-HELM-PROVENANCE" >"$BUILD_ARTIFACTS_DIR/aerospike-hello-0.4.2.tgz.prov"
echo "  Created aerospike-hello-0.4.2.tgz (Helm chart) + .prov"

# Create some additional test files with valid formats
# Create a valid JAR file (JAR is a ZIP with META-INF/MANIFEST.MF)
mkdir -p "$BUILD_ARTIFACTS_DIR/temp-jar/META-INF"
echo "Manifest-Version: 1.0" >"$BUILD_ARTIFACTS_DIR/temp-jar/META-INF/MANIFEST.MF"
cd "$BUILD_ARTIFACTS_DIR/temp-jar" && zip -q -r "../test.jar" . && cd - >/dev/null
rm -rf "$BUILD_ARTIFACTS_DIR/temp-jar"

# Create a Maven POM next to the JAR. Maven publishes artifacts as a
# (jar, pom, .md5, .sha1, .asc) bundle that share the same stem; this fixture
# exercises that grouping in the deploy-artifacts logic.
cat >"$BUILD_ARTIFACTS_DIR/test.pom" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example.test</groupId>
  <artifactId>test</artifactId>
  <version>1.0.0</version>
</project>
POM
echo "  Created test.pom (Maven POM companion)"

# Maven sidecar checksums (.md5, .sha1) computed from the actual files —
# JFrog Artifactory rejects checksum sidecars whose content isn't a valid
# hash format, so empty placeholders won't survive an end-to-end upload.
md5sum "$BUILD_ARTIFACTS_DIR/test.jar" >"$BUILD_ARTIFACTS_DIR/test.jar.md5"
sha1sum "$BUILD_ARTIFACTS_DIR/test.jar" >"$BUILD_ARTIFACTS_DIR/test.jar.sha1"
md5sum "$BUILD_ARTIFACTS_DIR/test.pom" >"$BUILD_ARTIFACTS_DIR/test.pom.md5"
sha1sum "$BUILD_ARTIFACTS_DIR/test.pom" >"$BUILD_ARTIFACTS_DIR/test.pom.sha1"
echo "  Created Maven sidecar checksums (test.{jar,pom}.{md5,sha1})"

# Standalone POM (BOM/parent-only) — has no companion JAR. structure_standalone_poms
# must still publish its sidecars; without that, the .md5/.sha1 fall through to
# structure_generic_files and get skipped because *.md5/*.sha1 are reserved for
# JAR processing in get_known_extensions.
cat >"$BUILD_ARTIFACTS_DIR/standalone-bom.pom" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example.bom</groupId>
  <artifactId>standalone-bom</artifactId>
  <version>1.0.0</version>
  <packaging>pom</packaging>
</project>
POM
md5sum "$BUILD_ARTIFACTS_DIR/standalone-bom.pom" >"$BUILD_ARTIFACTS_DIR/standalone-bom.pom.md5"
sha1sum "$BUILD_ARTIFACTS_DIR/standalone-bom.pom" >"$BUILD_ARTIFACTS_DIR/standalone-bom.pom.sha1"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/standalone-bom.pom.asc"
echo "  Created standalone POM (standalone-bom.pom + .md5/.sha1/.asc)"

# JFrog Maven repo layout (nested download paths). Exercises recursive find in
# detect_types / deploy when artifacts are not flat in build-artifacts/.
make_maven_jar_with_coords() {
    local out="$1" group_id="$2" artifact_id="$3" version="$4"
    local tmp props_dir out_dir
    mkdir -p "$(dirname "$out")"
    out_dir=$(cd "$(dirname "$out")" && pwd)
    out="$out_dir/$(basename "$out")"
    tmp=$(mktemp -d)
    mkdir -p "$tmp/META-INF"
    echo "Manifest-Version: 1.0" >"$tmp/META-INF/MANIFEST.MF"
    props_dir="$tmp/META-INF/maven/${group_id}/${artifact_id}"
    mkdir -p "$props_dir"
    cat >"$props_dir/pom.properties" <<EOF
groupId=${group_id}
artifactId=${artifact_id}
version=${version}
EOF
    (cd "$tmp" && zip -q -r "$out" .)
    rm -rf "$tmp"
}

MAVEN_REPO="$BUILD_ARTIFACTS_DIR/maven-repo"

# 1. Normal jar + pom + asc
dir="$MAVEN_REPO/com/example/app/my-app/1.0.0"
mkdir -p "$dir"
make_maven_jar_with_coords "$dir/my-app-1.0.0.jar" "com.example.app" "my-app" "1.0.0"
cat >"$dir/my-app-1.0.0.pom" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example.app</groupId>
  <artifactId>my-app</artifactId>
  <version>1.0.0</version>
  <packaging>jar</packaging>
</project>
POM
echo "FAKE-GPG-SIGNATURE" >"$dir/my-app-1.0.0.jar.asc"
echo "FAKE-GPG-SIGNATURE" >"$dir/my-app-1.0.0.pom.asc"
echo "  Created maven-repo my-app (jar+pom+asc)"

# 2. Parent aggregator + two children
dir="$MAVEN_REPO/com/example/parent/parent-proj/1.0.0"
mkdir -p "$dir"
cat >"$dir/parent-proj-1.0.0.pom" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example.parent</groupId>
  <artifactId>parent-proj</artifactId>
  <version>1.0.0</version>
  <packaging>pom</packaging>
  <modules>
    <module>child-one</module>
    <module>child-two</module>
  </modules>
</project>
POM
echo "FAKE-GPG-SIGNATURE" >"$dir/parent-proj-1.0.0.pom.asc"

for child in child-one child-two; do
    dir="$MAVEN_REPO/com/example/parent/${child}/1.0.0"
    mkdir -p "$dir"
    make_maven_jar_with_coords "$dir/${child}-1.0.0.jar" "com.example.parent" "$child" "1.0.0"
    cat >"$dir/${child}-1.0.0.pom" <<POM
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>com.example.parent</groupId>
    <artifactId>parent-proj</artifactId>
    <version>1.0.0</version>
  </parent>
  <artifactId>${child}</artifactId>
  <packaging>jar</packaging>
</project>
POM
    echo "FAKE-GPG-SIGNATURE" >"$dir/${child}-1.0.0.jar.asc"
    echo "FAKE-GPG-SIGNATURE" >"$dir/${child}-1.0.0.pom.asc"
done
echo "  Created maven-repo parent-proj + child-one + child-two"

# 3. Nested standalone BOM (distinct version from flat standalone-bom)
dir="$MAVEN_REPO/com/example/bom/standalone-bom/2.1.0"
mkdir -p "$dir"
cat >"$dir/standalone-bom-2.1.0.pom" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example.bom</groupId>
  <artifactId>standalone-bom</artifactId>
  <version>2.1.0</version>
  <packaging>pom</packaging>
</project>
POM
echo "FAKE-GPG-SIGNATURE" >"$dir/standalone-bom-2.1.0.pom.asc"
echo "  Created maven-repo standalone-bom-2.1.0 (pom+asc only)"

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
    cp "tests/test-1.0-2.noarch.rpm" "$BUILD_ARTIFACTS_DIR/nested/dir/test-1.0-2.el9.noarch.rpm"
    echo "   Copied test-1.0-2.noarch.rpm as nested/dir/test-1.0-2.el9.noarch.rpm"
else
    echo "Error: tests/test-1.0-2.noarch.rpm not found. This file is required for nested test fixtures." >&2
    exit 1
fi

# Create .asc companion files (simulated detached GPG signatures)
# In production, the sign stage creates these alongside every artifact
echo "Creating .asc companion files..."
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/test.jar.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/test.pom.asc"
# Signed Maven sidecar checksums: the sign stage GPG-signs every non-.asc file,
# which includes .md5/.sha1, producing .md5.asc/.sha1.asc companions.
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/test.jar.md5.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/test.jar.sha1.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/test.pom.md5.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/test.pom.sha1.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/test-ubuntu22.04.deb.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/test-1.0-2.el9.noarch.rpm.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/test-all-arch_1.0.0-1ubuntu22.04_all.deb.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/Aerospike.Client.8.0.2.nupkg.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/nuget/Aerospike.HelloWorld.1.0.0.nupkg.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/nuget/Aerospike.HelloWorld.1.0.0.snupkg.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/nested/dir/test-debian12.deb.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/nested/dir/test-1.0-2.el9.noarch.rpm.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/aerospike-test-package-1.0.0.tgz.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/aerospike-6.0.0.tgz.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/aerospike_hello-1.0.0-py3-none-any.whl.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/aerospike-hello-1.0.0.tar.gz.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/aerospike-utils-2.0.0.tgz.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/aerospike-targz-package-3.0.0.tar.gz.asc"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/aeromod-v1.2.3.zip.asc"
# Note: no .asc for the helm chart. sign-artifacts produces a .prov for helm
# charts (helm-native provenance signature), not a detached .asc. The .prov
# fixture above is what arrives at deploy.

# Windows installer payloads (win type: .exe / .msi / .msix)
head -c 2048 /dev/zero >"$BUILD_ARTIFACTS_DIR/ci-win-fixture.exe"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/ci-win-fixture.exe.asc"
head -c 2048 /dev/zero >"$BUILD_ARTIFACTS_DIR/ci-win-fixture.msi"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/ci-win-fixture.msi.asc"
head -c 2048 /dev/zero >"$BUILD_ARTIFACTS_DIR/ci-win-fixture.msix"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/ci-win-fixture.msix.asc"

# Rust crate (.crate): cargo pack layout with Cargo.toml [package] name/version
mkdir -p "$BUILD_ARTIFACTS_DIR/temp-crate/aerospike-3.0.0-alpha.1/src"
cat >"$BUILD_ARTIFACTS_DIR/temp-crate/aerospike-3.0.0-alpha.1/Cargo.toml" <<'CARGO'
[package]
name = "aerospike"
version = "3.0.0-alpha.1"
edition = "2021"
CARGO
echo 'pub fn placeholder() {}' >"$BUILD_ARTIFACTS_DIR/temp-crate/aerospike-3.0.0-alpha.1/src/lib.rs"
cd "$BUILD_ARTIFACTS_DIR/temp-crate" && tar -czf "../aerospike-3.0.0-alpha.1.crate" aerospike-3.0.0-alpha.1/ && cd - >/dev/null
rm -rf "$BUILD_ARTIFACTS_DIR/temp-crate"
echo "  Created aerospike-3.0.0-alpha.1.crate (Rust crate)"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/aerospike-3.0.0-alpha.1.crate.asc"
# Invalid .crate (wrong extension content) for validation tests
echo "not-a-valid-crate-archive" >"$BUILD_ARTIFACTS_DIR/invalid-fixture.crate"

# Create unsigned-artifacts/ prefix to simulate sign stage output
# The sign stage uses cp --parents which creates: signed-artifacts/unsigned-artifacts/...
# Deploy receives this as: build-artifacts/unsigned-artifacts/...
mkdir -p "$BUILD_ARTIFACTS_DIR/unsigned-artifacts/net8.0"
echo "generic-content" >"$BUILD_ARTIFACTS_DIR/unsigned-artifacts/net8.0/app.dll"
echo "FAKE-GPG-SIGNATURE" >"$BUILD_ARTIFACTS_DIR/unsigned-artifacts/net8.0/app.dll.asc"

echo "Test files created:"
find "$BUILD_ARTIFACTS_DIR" -type f | sort
