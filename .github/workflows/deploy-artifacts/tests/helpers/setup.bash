#!/usr/bin/env bash
# Setup and teardown functions for bats tests

# Find the git root directory
GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_ARTIFACTS_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts"

# Define test directory
TEST_DIR="$DEPLOY_ARTIFACTS_DIR/test-artifacts"
BUILD_ARTIFACTS_DIR="$TEST_DIR/build-artifacts"

# Setup function called before each test file
setup_test_artifacts() {
        # Create test directory and fixtures
        rm -rf "$TEST_DIR"
        mkdir -p "$BUILD_ARTIFACTS_DIR"

        # Run create-test-fixtures.sh to set up test artifacts
        # Must run from git root so it can find tests/ directory
        cd "$GIT_ROOT" || exit 1
        "$DEPLOY_ARTIFACTS_DIR/create-test-fixtures.sh"
        cd "$DEPLOY_ARTIFACTS_DIR/test-artifacts" || exit 1

        # Verify test files exist
        TEST_FILES=(
                "$BUILD_ARTIFACTS_DIR/test-ubuntu22.04.deb"
                "$BUILD_ARTIFACTS_DIR/test-ubuntu22.04.deb.asc"
                "$BUILD_ARTIFACTS_DIR/test-1.0-2.el9.noarch.rpm"
                "$BUILD_ARTIFACTS_DIR/test-1.0-2.el9.noarch.rpm.asc"
                "$BUILD_ARTIFACTS_DIR/test-all-arch_1.0.0-1ubuntu22.04_all.deb"
                "$BUILD_ARTIFACTS_DIR/test-all-arch_1.0.0-1ubuntu22.04_all.deb.asc"
                "$BUILD_ARTIFACTS_DIR/test.jar"
                "$BUILD_ARTIFACTS_DIR/test.jar.asc"
                "$BUILD_ARTIFACTS_DIR/test.pom"
                "$BUILD_ARTIFACTS_DIR/test.pom.asc"
                "$BUILD_ARTIFACTS_DIR/test.module"
                "$BUILD_ARTIFACTS_DIR/test.module.asc"
                "$BUILD_ARTIFACTS_DIR/test.jar.md5"
                "$BUILD_ARTIFACTS_DIR/test.jar.sha1"
                "$BUILD_ARTIFACTS_DIR/test.pom.md5"
                "$BUILD_ARTIFACTS_DIR/test.pom.sha1"
                "$BUILD_ARTIFACTS_DIR/test.module.md5"
                "$BUILD_ARTIFACTS_DIR/test.module.sha1"
                "$BUILD_ARTIFACTS_DIR/test.jar.md5.asc"
                "$BUILD_ARTIFACTS_DIR/test.jar.sha1.asc"
                "$BUILD_ARTIFACTS_DIR/test.pom.md5.asc"
                "$BUILD_ARTIFACTS_DIR/test.pom.sha1.asc"
                "$BUILD_ARTIFACTS_DIR/test.module.md5.asc"
                "$BUILD_ARTIFACTS_DIR/test.module.sha1.asc"
                "$BUILD_ARTIFACTS_DIR/standalone-bom.pom"
                "$BUILD_ARTIFACTS_DIR/standalone-bom.pom.md5"
                "$BUILD_ARTIFACTS_DIR/standalone-bom.pom.sha1"
                "$BUILD_ARTIFACTS_DIR/standalone-bom.pom.asc"
                "$BUILD_ARTIFACTS_DIR/standalone-bom.module"
                "$BUILD_ARTIFACTS_DIR/standalone-bom.module.md5"
                "$BUILD_ARTIFACTS_DIR/standalone-bom.module.sha1"
                "$BUILD_ARTIFACTS_DIR/standalone-bom.module.asc"
                "$BUILD_ARTIFACTS_DIR/maven-repo/com/example/app/my-app/1.0.0/my-app-1.0.0.jar"
                "$BUILD_ARTIFACTS_DIR/maven-repo/com/example/app/my-app/1.0.0/my-app-1.0.0.pom"
                "$BUILD_ARTIFACTS_DIR/maven-repo/com/example/app/my-app/1.0.0/my-app-1.0.0.module"
                "$BUILD_ARTIFACTS_DIR/maven-repo/com/example/parent/parent-proj/1.0.0/parent-proj-1.0.0.pom"
                "$BUILD_ARTIFACTS_DIR/maven-repo/com/example/parent/child-one/1.0.0/child-one-1.0.0.jar"
                "$BUILD_ARTIFACTS_DIR/maven-repo/com/example/parent/child-two/1.0.0/child-two-1.0.0.jar"
                "$BUILD_ARTIFACTS_DIR/maven-repo/com/example/bom/standalone-bom/2.1.0/standalone-bom-2.1.0.pom"
                "$BUILD_ARTIFACTS_DIR/maven-repo/com/example/bom/standalone-bom/2.1.0/standalone-bom-2.1.0.module"
                "$BUILD_ARTIFACTS_DIR/test.zip"
                "$BUILD_ARTIFACTS_DIR/test.zip.asc"
                "$BUILD_ARTIFACTS_DIR/test.tar.gz"
                "$BUILD_ARTIFACTS_DIR/nested/dir/test-debian12.deb"
                "$BUILD_ARTIFACTS_DIR/nested/dir/test-debian12.deb.asc"
                "$BUILD_ARTIFACTS_DIR/nested/dir/test-1.0-2.el9.noarch.rpm"
                "$BUILD_ARTIFACTS_DIR/nested/dir/test-1.0-2.el9.noarch.rpm.asc"
                "$BUILD_ARTIFACTS_DIR/Aerospike.Client.8.0.2.nupkg"
                "$BUILD_ARTIFACTS_DIR/Aerospike.Client.8.0.2.nupkg.asc"
                "$BUILD_ARTIFACTS_DIR/nuget/Aerospike.HelloWorld.1.0.0.nupkg"
                "$BUILD_ARTIFACTS_DIR/nuget/Aerospike.HelloWorld.1.0.0.nupkg.asc"
                "$BUILD_ARTIFACTS_DIR/nuget/Aerospike.HelloWorld.1.0.0.snupkg"
                "$BUILD_ARTIFACTS_DIR/nuget/Aerospike.HelloWorld.1.0.0.snupkg.asc"
                "$BUILD_ARTIFACTS_DIR/unsigned-artifacts/net8.0/app.dll"
                "$BUILD_ARTIFACTS_DIR/unsigned-artifacts/net8.0/app.dll.asc"
                "$BUILD_ARTIFACTS_DIR/aerospike-test-package-1.0.0.tgz"
                "$BUILD_ARTIFACTS_DIR/aerospike-test-package-1.0.0.tgz.asc"
                "$BUILD_ARTIFACTS_DIR/aerospike-6.0.0.tgz"
                "$BUILD_ARTIFACTS_DIR/aerospike-6.0.0.tgz.asc"
                "$BUILD_ARTIFACTS_DIR/generic-archive.tgz"
                "$BUILD_ARTIFACTS_DIR/aerospike-utils-2.0.0.tgz"
                "$BUILD_ARTIFACTS_DIR/aerospike-utils-2.0.0.tgz.asc"
                "$BUILD_ARTIFACTS_DIR/aerospike-targz-package-3.0.0.tar.gz"
                "$BUILD_ARTIFACTS_DIR/aerospike-targz-package-3.0.0.tar.gz.asc"
                "$BUILD_ARTIFACTS_DIR/aerospike_hello-1.0.0-py3-none-any.whl"
                "$BUILD_ARTIFACTS_DIR/aerospike_hello-1.0.0-py3-none-any.whl.asc"
                "$BUILD_ARTIFACTS_DIR/aerospike-hello-1.0.0.tar.gz"
                "$BUILD_ARTIFACTS_DIR/aerospike-hello-1.0.0.tar.gz.asc"
                "$BUILD_ARTIFACTS_DIR/aeromod-v1.2.3.zip"
                "$BUILD_ARTIFACTS_DIR/aeromod-v1.2.3.zip.asc"
                "$BUILD_ARTIFACTS_DIR/aerospike-hello-0.4.2.tgz"
                "$BUILD_ARTIFACTS_DIR/aerospike-hello-0.4.2.tgz.prov"
                "$BUILD_ARTIFACTS_DIR/ci-win-fixture.exe"
                "$BUILD_ARTIFACTS_DIR/ci-win-fixture.exe.asc"
                "$BUILD_ARTIFACTS_DIR/ci-win-fixture.msi"
                "$BUILD_ARTIFACTS_DIR/ci-win-fixture.msi.asc"
                "$BUILD_ARTIFACTS_DIR/ci-win-fixture.msix"
                "$BUILD_ARTIFACTS_DIR/ci-win-fixture.msix.asc"
                "$BUILD_ARTIFACTS_DIR/aerospike-3.0.0-alpha.1.crate"
                "$BUILD_ARTIFACTS_DIR/aerospike-3.0.0-alpha.1.crate.asc"
                "$BUILD_ARTIFACTS_DIR/invalid-fixture.crate"
        )

        for file in "${TEST_FILES[@]}"; do
                if [[ ! -f $file ]]; then
                        echo "Error: Missing expected test file: $file" >&2
                        exit 1
                fi
        done

        # Change to test directory for consistent context
        cd "$TEST_DIR" || exit 1
}

teardown_test_artifacts() {
        # Cleanup test artifacts (optional - comment out for debugging)
        # rm -rf "$TEST_DIR"
        :
}

# Run entrypoint.sh with dry-run and capture output
run_entrypoint_dry_run() {
        local project="${1:-test-project}"
        local build_name="${2:-test-build}"
        local version="${3:-v1.0.0}"
        local build_number="${4:-12345}"
        local metadata_build_number="${5:-12345-metadata}"

        cd "$TEST_DIR" || exit 1

        # Run detection script
        "$DEPLOY_ARTIFACTS_DIR/detect_types.sh" \
                --artifacts-dir "$BUILD_ARTIFACTS_DIR" \
                2>&1

        # Run deploy script
        # Set required environment variables for NuGet CLI
        export JF_URL="${JF_URL:-https://artifact.aerospike.io}"
        export OIDC_USER="${OIDC_USER:-test-user@aerospike.com}"
        export OIDC_TOKEN="${OIDC_TOKEN:-test-token}"
        "$DEPLOY_ARTIFACTS_DIR/entrypoint.sh" \
                "$project" \
                "$build_name" \
                "$version" \
                "$build_number" \
                "$metadata_build_number" \
                --dry-run \
                --jar-group-id "com.example.test" \
                2>&1
}
