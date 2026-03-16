#!/usr/bin/env bats
# Unit tests for type_registry.sh configuration and props functions.
# These source the registry directly without running the full entrypoint.

GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts"

setup() {
    # Need package_utils.sh for metadata extraction used by props functions
    source "$DEPLOY_DIR/package_utils.sh"
    source "$DEPLOY_DIR/type_registry.sh"
    # package_utils.sh sets strict mode and an ERR trap that interferes with bats assertions
    set +eu
    trap - ERR
}

# --- Registry configuration ---

@test "TYPE_EXTENSIONS has entries for all standard types" {
    [[ "${TYPE_EXTENSIONS[deb]}" == "*.deb" ]]
    [[ "${TYPE_EXTENSIONS[rpm]}" == "*.rpm" ]]
    [[ "${TYPE_EXTENSIONS[jar]}" == "*.jar" ]]
    [[ "${TYPE_EXTENSIONS[nupkg]}" == "*.nupkg" ]]
    [[ "${TYPE_EXTENSIONS[snupkg]}" == "*.snupkg" ]]
    # Generic is NOT in TYPE_EXTENSIONS -- it's the catch-all
    [[ -z "${TYPE_EXTENSIONS[generic]}" ]]
}

@test "TYPE_REPO maps types to correct JFrog repo suffixes" {
    [[ "${TYPE_REPO[deb]}" == "deb-dev-local" ]]
    [[ "${TYPE_REPO[rpm]}" == "rpm-dev-local" ]]
    [[ "${TYPE_REPO[jar]}" == "maven-dev-local" ]]
    [[ "${TYPE_REPO[nupkg]}" == "nuget-dev-local" ]]
    [[ "${TYPE_REPO[generic]}" == "generic-dev-local" ]]
}

@test "TYPE_COMPANIONS defines companion suffixes for all types" {
    [[ "${TYPE_COMPANIONS[deb]}" == ".asc" ]]
    [[ "${TYPE_COMPANIONS[rpm]}" == ".asc" ]]
    [[ "${TYPE_COMPANIONS[jar]}" == ".pom .asc .pom.asc" ]]
    [[ "${TYPE_COMPANIONS[generic]}" == ".asc" ]]
}

@test "UPLOAD_ORDER has jar before generic" {
    local jar_idx=-1
    local generic_idx=-1
    for i in "${!UPLOAD_ORDER[@]}"; do
        [[ "${UPLOAD_ORDER[$i]}" == "jar" ]] && jar_idx=$i
        [[ "${UPLOAD_ORDER[$i]}" == "generic" ]] && generic_idx=$i
    done
    [[ $jar_idx -lt $generic_idx ]]
}

# --- get_known_extensions ---

@test "get_known_extensions includes all registered extensions" {
    local exts
    exts=$(get_known_extensions)
    [[ "$exts" == *"*.deb"* ]]
    [[ "$exts" == *"*.rpm"* ]]
    [[ "$exts" == *"*.jar"* ]]
    [[ "$exts" == *"*.nupkg"* ]]
    [[ "$exts" == *"*.snupkg"* ]]
}

@test "get_known_extensions includes companion and build file extensions" {
    local exts
    exts=$(get_known_extensions)
    [[ "$exts" == *"*.asc"* ]]
    [[ "$exts" == *"*.pom"* ]]
    [[ "$exts" == *"*.csproj"* ]]
}

# --- get_base_props ---

@test "get_base_props returns version" {
    VERSION="1.2.3"
    BUILD_TYPE=""
    INTERNAL="false"
    local props
    props=$(get_base_props)
    [[ "$props" == "version=1.2.3" ]]
}

@test "get_base_props includes build.type when set" {
    VERSION="1.2.3"
    BUILD_TYPE="nightly"
    INTERNAL="false"
    local props
    props=$(get_base_props)
    [[ "$props" == *"version=1.2.3"* ]]
    [[ "$props" == *"build.type=nightly"* ]]
}

@test "get_base_props includes internal when true" {
    VERSION="1.2.3"
    BUILD_TYPE=""
    INTERNAL="true"
    local props
    props=$(get_base_props)
    [[ "$props" == *"version=1.2.3"* ]]
    [[ "$props" == *"internal=true"* ]]
}

@test "get_base_props includes both build.type and internal" {
    VERSION="2.0.0"
    BUILD_TYPE="release"
    INTERNAL="true"
    local props
    props=$(get_base_props)
    [[ "$props" == *"version=2.0.0"* ]]
    [[ "$props" == *"build.type=release"* ]]
    [[ "$props" == *"internal=true"* ]]
}

@test "get_base_props omits build.type when empty" {
    VERSION="1.0.0"
    BUILD_TYPE=""
    INTERNAL="false"
    local props
    props=$(get_base_props)
    [[ "$props" != *"build.type"* ]]
}

@test "get_base_props omits internal when false" {
    VERSION="1.0.0"
    BUILD_TYPE=""
    INTERNAL="false"
    local props
    props=$(get_base_props)
    [[ "$props" != *"internal"* ]]
}

# --- get_generic_props ---

@test "get_generic_props includes version and package_name" {
    VERSION="3.0.0"
    BUILD_TYPE=""
    INTERNAL="false"
    local props
    props=$(get_generic_props "/some/path/myfile.tar.gz")
    [[ "$props" == *"version=3.0.0"* ]]
    [[ "$props" == *"package_name=myfile.tar.gz"* ]]
}

# --- get_deb_props ---

@test "get_deb_props returns correct props for deb file with known distro" {
    # The test fixture create-test-fixtures.sh copies nano-tiny as test-ubuntu22.04.deb
    local test_dir
    test_dir=$(mktemp -d)
    cp "$GIT_ROOT/tests/nano-tiny_8.4-1_arm64.deb" "$test_dir/test-ubuntu22.04.deb"
    VERSION="1.0.0"
    BUILD_TYPE=""
    INTERNAL="false"
    local props
    props=$(get_deb_props "$test_dir/test-ubuntu22.04.deb" 2>/dev/null)
    [[ "$props" == *"version=1.0.0"* ]]
    [[ "$props" == *"deb.distribution=jammy"* ]]
    [[ "$props" == *"deb.component=main"* ]]
    [[ "$props" == *"package_name="* ]]
    rm -rf "$test_dir"
}
