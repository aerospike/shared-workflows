#!/usr/bin/env bats
# Unit tests for type_registry.sh configuration and props functions.
# These source the registry directly without running the full entrypoint.

GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts"

setup() {
    # Need package_utils.sh for metadata extraction used by props functions
    source "$DEPLOY_DIR/../lib/helm-helpers.sh"
    source "$DEPLOY_DIR/package_utils.sh"
    source "$DEPLOY_DIR/type_registry.sh"
    # package_utils.sh sets strict mode and an ERR trap that interferes with bats assertions
    set +eu
    trap - ERR
}

# --- Registry configuration ---

@test "TYPE_EXTENSIONS has entries for all extension-based types" {
    [[ "${TYPE_EXTENSIONS[deb]}" == "*.deb" ]]
    [[ "${TYPE_EXTENSIONS[rpm]}" == "*.rpm" ]]
    [[ "${TYPE_EXTENSIONS[jar]}" == "*.jar" ]]
    [[ "${TYPE_EXTENSIONS[nupkg]}" == "*.nupkg" ]]
    [[ "${TYPE_EXTENSIONS[snupkg]}" == "*.snupkg" ]]
    [[ "${TYPE_EXTENSIONS[pypi]}" == "*.whl" ]]
    [[ "${TYPE_EXTENSIONS[crate]}" == "*.crate" ]]
    [[ "${TYPE_EXTENSIONS[win]}" == "*.exe,*.msi,*.msix" ]]
    # npm uses content detection (*.tgz is ambiguous), not in TYPE_EXTENSIONS
    [[ -z "${TYPE_EXTENSIONS[npm]}" ]]
    # Generic is NOT in TYPE_EXTENSIONS -- it's the catch-all
    [[ -z "${TYPE_EXTENSIONS[generic]}" ]]
}

@test "TYPE_REPO maps types to correct JFrog repo suffixes" {
    [[ "${TYPE_REPO[deb]}" == "deb-dev-local" ]]
    [[ "${TYPE_REPO[rpm]}" == "rpm-dev-local" ]]
    [[ "${TYPE_REPO[jar]}" == "maven-dev-local" ]]
    [[ "${TYPE_REPO[nupkg]}" == "nuget-dev-local" ]]
    [[ "${TYPE_REPO[npm]}" == "npm-dev-local" ]]
    [[ "${TYPE_REPO[pypi]}" == "pypi-dev-local" ]]
    [[ "${TYPE_REPO[go]}" == "go-dev-local" ]]
    [[ "${TYPE_REPO[helm]}" == "helm-dev-local" ]]
    [[ "${TYPE_REPO[crate]}" == "generic-dev-local" ]]
    [[ "${TYPE_REPO[win]}" == "generic-dev-local" ]]
    [[ "${TYPE_REPO[generic]}" == "generic-dev-local" ]]
}

@test "TYPE_COMPANIONS defines companion suffixes for all types" {
    [[ "${TYPE_COMPANIONS[deb]}" == ".asc" ]]
    [[ "${TYPE_COMPANIONS[rpm]}" == ".asc" ]]
    [[ "${TYPE_COMPANIONS[jar]}" == ".pom .asc .pom.asc" ]]
    [[ "${TYPE_COMPANIONS[npm]}" == ".asc" ]]
    [[ "${TYPE_COMPANIONS[pypi]}" == ".asc" ]]
    [[ "${TYPE_COMPANIONS[helm]}" == ".prov" ]]
    [[ "${TYPE_COMPANIONS[crate]}" == ".asc" ]]
    [[ "${TYPE_COMPANIONS[win]}" == ".asc" ]]
    [[ "${TYPE_COMPANIONS[generic]}" == ".asc" ]]
}

@test "CONTENT_DETECT_EXTENSIONS lists ambiguous extensions" {
    [[ "${CONTENT_DETECT_EXTENSIONS[*]}" == *"*.tgz"* ]]
    [[ "${CONTENT_DETECT_EXTENSIONS[*]}" == *"*.tar.gz"* ]]
    [[ "${CONTENT_DETECT_EXTENSIONS[*]}" == *"*.zip"* ]]
}

@test "TYPE_CONTENT_DETECT maps types to detection functions" {
    [[ "${TYPE_CONTENT_DETECT[npm]}" == "is_npm_package" ]]
    [[ "${TYPE_CONTENT_DETECT[pypi]}" == "is_pypi_package" ]]
    [[ "${TYPE_CONTENT_DETECT[go]}" == "is_go_module" ]]
    [[ "${TYPE_CONTENT_DETECT[helm]}" == "is_helm_chart" ]]
}

@test "CONTENT_DETECT_ORDER defines detection priority" {
    [[ "${CONTENT_DETECT_ORDER[0]}" == "npm" ]]
    [[ "${CONTENT_DETECT_ORDER[1]}" == "pypi" ]]
    [[ "${CONTENT_DETECT_ORDER[2]}" == "go" ]]
    [[ "${CONTENT_DETECT_ORDER[3]}" == "helm" ]]
}

@test "UPLOAD_ORDER has jar, pypi, go, crate, win and helm before generic" {
    local jar_idx=-1
    local pypi_idx=-1
    local go_idx=-1
    local crate_idx=-1
    local helm_idx=-1
    local win_idx=-1
    local generic_idx=-1
    for i in "${!UPLOAD_ORDER[@]}"; do
        [[ "${UPLOAD_ORDER[$i]}" == "jar" ]] && jar_idx=$i
        [[ "${UPLOAD_ORDER[$i]}" == "pypi" ]] && pypi_idx=$i
        [[ "${UPLOAD_ORDER[$i]}" == "go" ]] && go_idx=$i
        [[ "${UPLOAD_ORDER[$i]}" == "crate" ]] && crate_idx=$i
        [[ "${UPLOAD_ORDER[$i]}" == "helm" ]] && helm_idx=$i
        [[ "${UPLOAD_ORDER[$i]}" == "win" ]] && win_idx=$i
        [[ "${UPLOAD_ORDER[$i]}" == "generic" ]] && generic_idx=$i
    done
    [[ $jar_idx -lt $generic_idx ]]
    [[ $pypi_idx -lt $generic_idx ]]
    [[ $helm_idx -lt $generic_idx ]]
    [[ $crate_idx -lt $generic_idx ]]
    [[ $win_idx -lt $generic_idx ]]
    [[ $go_idx -lt $win_idx ]]
    [[ $crate_idx -lt $win_idx ]]
    [[ $pypi_idx -gt 0 ]]
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
    [[ "$exts" == *"*.tgz"* ]]
    [[ "$exts" == *"*.whl"* ]]
    [[ "$exts" == *"*.exe"* ]]
    [[ "$exts" == *"*.msi"* ]]
    [[ "$exts" == *"*.msix"* ]]
    [[ "$exts" == *"*.crate"* ]]
}

@test "emit_type_extension_globs splits on comma and trims spaces" {
    local out
    out=$(emit_type_extension_globs "*.a, *.b ,*.c")
    [[ $(echo "$out" | wc -l | tr -d ' ') -eq 3 ]]
    echo "$out" | grep -qxF '*.a'
    echo "$out" | grep -qxF '*.b'
    echo "$out" | grep -qxF '*.c'
}

@test "get_known_extensions emits one line per glob for comma-separated TYPE_EXTENSIONS" {
    TYPE_EXTENSIONS[multitype]="*.one, *.two"
    local exts
    exts=$(get_known_extensions)
    [[ $(echo "$exts" | grep -cF '*.one') -eq 1 ]]
    echo "$exts" | grep -qF '*.two'
}

@test "get_known_extensions includes content-detected, companion, and build file extensions" {
    local exts
    exts=$(get_known_extensions)
    # Content-detected extensions
    [[ "$exts" == *"*.tgz"* ]]
    [[ "$exts" == *"*.tar.gz"* ]]
    # Companion and build file extensions
    [[ "$exts" == *"*.asc"* ]]
    [[ "$exts" == *"*.prov"* ]]
    [[ "$exts" == *"*.pom"* ]]
    [[ "$exts" == *"*.csproj"* ]]
    # Maven sidecar checksums must be excluded from generic structuring,
    # otherwise structure_generic_files double-structures them and JFrog's
    # checksum-deploy interception 404s on the generic-repo upload (the .jar
    # base file lives in maven-dev-local, not generic-dev-local).
    [[ "$exts" == *"*.md5"* ]]
    [[ "$exts" == *"*.sha1"* ]]
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

@test "get_win_props matches get_generic_props shape" {
    VERSION="2.1.0"
    BUILD_TYPE=""
    INTERNAL="false"
    local props
    props=$(get_win_props "/some/path/installer.msi")
    [[ "$props" == *"version=2.1.0"* ]]
    [[ "$props" == *"package_name=installer.msi"* ]]
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

# --- get_npm_props ---

@test "get_go_props returns correct props for Go module zip" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/github.com/aerospike/testmod@v1.0.0"
    echo "module github.com/aerospike/testmod" > "$test_dir/github.com/aerospike/testmod@v1.0.0/go.mod"
    cd "$test_dir" && zip -q -r "gomod.zip" "github.com/" && cd - >/dev/null
    VERSION="1.0.0"
    BUILD_TYPE=""
    INTERNAL="false"
    local props
    props=$(get_go_props "$test_dir/gomod.zip" 2>/dev/null)
    [[ "$props" == *"version=1.0.0"* ]]
    [[ "$props" == *"package_name=github.com/aerospike/testmod"* ]]
    [[ "$props" == *"go.module=github.com/aerospike/testmod"* ]]
    [[ "$props" == *"go.version=v1.0.0"* ]]
    rm -rf "$test_dir"
}

@test "get_npm_props returns correct props for npm package" {
    local test_dir
    test_dir=$(mktemp -d)
    # Create a valid npm package tarball
    mkdir -p "$test_dir/package"
    echo '{"name":"@aerospike/test-pkg","version":"2.0.0"}' > "$test_dir/package/package.json"
    tar -czf "$test_dir/test-pkg-2.0.0.tgz" -C "$test_dir" package/
    rm -rf "$test_dir/package"
    VERSION="2.0.0"
    BUILD_TYPE=""
    INTERNAL="false"
    local props
    props=$(get_npm_props "$test_dir/test-pkg-2.0.0.tgz" 2>/dev/null)
    [[ "$props" == *"version=2.0.0"* ]]
    [[ "$props" == *"package_name=@aerospike/test-pkg"* ]]
    rm -rf "$test_dir"
}

# --- get_helm_props ---

@test "get_crate_props returns correct props for Rust crate" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/aerospike-3.0.0-alpha.1/src"
    cat >"$test_dir/aerospike-3.0.0-alpha.1/Cargo.toml" <<'CARGO'
[package]
name = "aerospike"
version = "3.0.0-alpha.1"
edition = "2021"
CARGO
    echo 'pub fn placeholder() {}' >"$test_dir/aerospike-3.0.0-alpha.1/src/lib.rs"
    cd "$test_dir" && tar -czf "aerospike-3.0.0-alpha.1.crate" aerospike-3.0.0-alpha.1/ && cd - >/dev/null
    VERSION="3.0.0-alpha.1"
    BUILD_TYPE=""
    INTERNAL="false"
    local props
    props=$(get_crate_props "$test_dir/aerospike-3.0.0-alpha.1.crate" 2>/dev/null)
    [[ "$props" == *"version=3.0.0-alpha.1"* ]]
    [[ "$props" == *"package_name=aerospike"* ]]
    [[ "$props" == *"cargo.name=aerospike"* ]]
    [[ "$props" == *"cargo.version=3.0.0-alpha.1"* ]]
    rm -rf "$test_dir"
}

@test "get_helm_props returns correct props for Helm chart" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/hello"
    cat > "$test_dir/hello/Chart.yaml" <<'YAML'
apiVersion: v2
name: hello
description: Test chart
type: application
version: 1.2.3
appVersion: "1.2.3"
YAML
    tar -czf "$test_dir/hello-1.2.3.tgz" -C "$test_dir" hello/
    rm -rf "$test_dir/hello"
    VERSION="1.2.3"
    BUILD_TYPE=""
    INTERNAL="false"
    local props
    props=$(get_helm_props "$test_dir/hello-1.2.3.tgz" 2>/dev/null)
    [[ "$props" == *"version=1.2.3"* ]]
    [[ "$props" == *"package_name=hello"* ]]
    [[ "$props" == *"helm.name=hello"* ]]
    [[ "$props" == *"helm.version=1.2.3"* ]]
    rm -rf "$test_dir"
}
