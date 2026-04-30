#!/usr/bin/env bats
# Unit tests for metadata extraction functions in package_utils.sh
# These test functions in isolation without running the full entrypoint.

GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts"

setup() {
    source "$DEPLOY_DIR/../lib/helm-helpers.sh"
    source "$DEPLOY_DIR/package_utils.sh"
    source "$DEPLOY_DIR/type_detection.sh"
    # package_utils.sh sets strict mode and an ERR trap that interferes with bats assertions
    set +eu
    trap - ERR
}

# --- get_codename_for_deb ---

@test "get_codename_for_deb maps ubuntu22.04 to jammy" {
    result=$(get_codename_for_deb "test-ubuntu22.04.deb")
    [[ "$result" == "jammy" ]]
}

@test "get_codename_for_deb maps ubuntu24.04 to noble" {
    result=$(get_codename_for_deb "test-ubuntu24.04.deb")
    [[ "$result" == "noble" ]]
}

@test "get_codename_for_deb maps ubuntu26.04 to resolute" {
    result=$(get_codename_for_deb "test-ubuntu26.04.deb")
    [[ "$result" == "resolute" ]]
}

@test "get_codename_for_deb maps ubuntu20.04 to focal" {
    result=$(get_codename_for_deb "test-ubuntu20.04.deb")
    [[ "$result" == "focal" ]]
}

@test "get_codename_for_deb maps debian11 to bullseye" {
    result=$(get_codename_for_deb "test-debian11.deb")
    [[ "$result" == "bullseye" ]]
}

@test "get_codename_for_deb maps debian12 to bookworm" {
    result=$(get_codename_for_deb "test-debian12.deb")
    [[ "$result" == "bookworm" ]]
}

@test "get_codename_for_deb maps debian13 to trixie" {
    result=$(get_codename_for_deb "test-debian13.deb")
    [[ "$result" == "trixie" ]]
}

@test "get_codename_for_deb fails for unknown distro" {
    run get_codename_for_deb "test-unknown.deb"
    [[ $status -ne 0 ]]
}

# --- DEB Architecture: all ---

@test "dpkg-deb reads Architecture: all from real deb" {
    local deb="$GIT_ROOT/tests/test-all-arch_1.0.0-1ubuntu22.04_all.deb"
    if [[ ! -f "$deb" ]]; then
        skip "Test fixture not available"
    fi
    local arch
    arch=$(dpkg-deb -f "$deb" Architecture)
    [[ "$arch" == "all" ]]
}

@test "dpkg-deb reads Package name from Architecture: all deb" {
    local deb="$GIT_ROOT/tests/test-all-arch_1.0.0-1ubuntu22.04_all.deb"
    if [[ ! -f "$deb" ]]; then
        skip "Test fixture not available"
    fi
    local pkg
    pkg=$(dpkg-deb -f "$deb" Package)
    [[ "$pkg" == "test-all-arch" ]]
}

@test "get_codename_for_deb works with Architecture: all deb filename" {
    result=$(get_codename_for_deb "test-all-arch_1.0.0-1ubuntu22.04_all.deb")
    [[ "$result" == "jammy" ]]
}

# --- get_nupkg_metadata ---

@test "get_nupkg_metadata extracts name and version from real nupkg" {
    local nupkg="$GIT_ROOT/tests/some/structure/Aerospike.Client.8.0.2.nupkg"
    if [[ ! -f "$nupkg" ]]; then
        skip "Test fixture not available"
    fi
    read -r -a meta < <(get_nupkg_metadata "$nupkg")
    [[ "${meta[0]}" == "Aerospike.Client" ]]
    [[ "${meta[1]}" == "8.0.2" ]]
}

# --- get_rpm_metadata ---

@test "get_rpm_metadata extracts metadata from real rpm" {
    local rpm_file="$GIT_ROOT/tests/test-1.0-2.noarch.rpm"
    if [[ ! -f "$rpm_file" ]]; then
        skip "Test fixture not available"
    fi
    read -r -a meta < <(get_rpm_metadata "$rpm_file")
    # pkgname
    [[ -n "${meta[0]}" ]]
    # arch
    [[ "${meta[2]}" == "noarch" ]]
}

# --- is_npm_package ---

@test "is_npm_package returns true for npm tarball" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/package"
    echo '{"name":"test","version":"1.0.0"}' > "$test_dir/package/package.json"
    tar -czf "$test_dir/npm-pkg.tgz" -C "$test_dir" package/
    rm -rf "$test_dir/package"
    is_npm_package "$test_dir/npm-pkg.tgz"
    rm -rf "$test_dir"
}

@test "is_npm_package returns false for non-npm tarball" {
    local test_dir
    test_dir=$(mktemp -d)
    echo "not npm" > "$test_dir/data.txt"
    tar -czf "$test_dir/plain.tgz" -C "$test_dir" data.txt
    rm -f "$test_dir/data.txt"
    run is_npm_package "$test_dir/plain.tgz"
    [[ $status -ne 0 ]]
    rm -rf "$test_dir"
}

# --- get_npm_metadata ---

@test "get_npm_metadata extracts name and version from tarball" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/package"
    echo '{"name":"@aerospike/my-lib","version":"3.2.1"}' > "$test_dir/package/package.json"
    tar -czf "$test_dir/my-lib-3.2.1.tgz" -C "$test_dir" package/
    rm -rf "$test_dir/package"
    read -r -a meta < <(get_npm_metadata "$test_dir/my-lib-3.2.1.tgz")
    [[ "${meta[0]}" == "@aerospike/my-lib" ]]
    [[ "${meta[1]}" == "3.2.1" ]]
    rm -rf "$test_dir"
}

@test "get_npm_metadata handles scoped package names" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/package"
    echo '{"name":"@scope/pkg","version":"0.1.0-beta.1"}' > "$test_dir/package/package.json"
    tar -czf "$test_dir/scope-pkg-0.1.0-beta.1.tgz" -C "$test_dir" package/
    rm -rf "$test_dir/package"
    read -r -a meta < <(get_npm_metadata "$test_dir/scope-pkg-0.1.0-beta.1.tgz")
    [[ "${meta[0]}" == "@scope/pkg" ]]
    [[ "${meta[1]}" == "0.1.0-beta.1" ]]
    rm -rf "$test_dir"
}

# --- _validate_npm_name ---

@test "_validate_npm_name rejects name with semicolons (property injection)" {
    run bash -c 'source "$DEPLOY_ARTIFACTS_DIR/package_utils.sh" && _validate_npm_name "evil;injected_prop=bar"'
    [[ $status -ne 0 ]]
}

@test "_validate_npm_name rejects name with spaces" {
    run bash -c 'source "$DEPLOY_ARTIFACTS_DIR/package_utils.sh" && _validate_npm_name "has spaces"'
    [[ $status -ne 0 ]]
}

@test "_validate_npm_name rejects uppercase names" {
    run bash -c 'source "$DEPLOY_ARTIFACTS_DIR/package_utils.sh" && _validate_npm_name "BadName"'
    [[ $status -ne 0 ]]
}

@test "_validate_npm_name accepts valid unscoped name" {
    _validate_npm_name "my-package"
}

@test "_validate_npm_name accepts valid scoped name" {
    _validate_npm_name "@aerospike/client"
}

# --- is_pypi_package (type_detection.sh; metadata-based sdist / wheel) ---

@test "is_pypi_package returns true for sdist tarball with PKG-INFO Name/Version" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/mypackage-1.0.0"
    echo -e "Metadata-Version: 2.1\nName: mypackage\nVersion: 1.0.0" > "$test_dir/mypackage-1.0.0/PKG-INFO"
    tar -czf "$test_dir/mypackage-1.0.0.tar.gz" -C "$test_dir" mypackage-1.0.0/
    rm -rf "$test_dir/mypackage-1.0.0"
    is_pypi_package "$test_dir/mypackage-1.0.0.tar.gz"
    rm -rf "$test_dir"
}

@test "is_pypi_package returns false for tarball without Python package metadata" {
    local test_dir
    test_dir=$(mktemp -d)
    echo "not a python package" > "$test_dir/data.txt"
    tar -czf "$test_dir/plain.tar.gz" -C "$test_dir" data.txt
    rm -f "$test_dir/data.txt"
    run is_pypi_package "$test_dir/plain.tar.gz"
    [[ $status -ne 0 ]]
    rm -rf "$test_dir"
}

# --- get_pypi_metadata ---

@test "get_pypi_metadata extracts name and version from wheel" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/temp-whl/aerospike_hello-2.0.0.dist-info"
    echo -e "Metadata-Version: 2.1\nName: aerospike-hello\nVersion: 2.0.0" > \
        "$test_dir/temp-whl/aerospike_hello-2.0.0.dist-info/METADATA"
    cd "$test_dir/temp-whl" && zip -q -r "../aerospike_hello-2.0.0-py3-none-any.whl" . && cd - >/dev/null
    rm -rf "$test_dir/temp-whl"
    read -r -a meta < <(get_pypi_metadata "$test_dir/aerospike_hello-2.0.0-py3-none-any.whl")
    [[ "${meta[0]}" == "aerospike-hello" ]]
    [[ "${meta[1]}" == "2.0.0" ]]
    rm -rf "$test_dir"
}

@test "get_pypi_metadata extracts name and version from sdist" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/aerospike-hello-3.0.0"
    echo -e "Metadata-Version: 2.1\nName: aerospike-hello\nVersion: 3.0.0" > \
        "$test_dir/aerospike-hello-3.0.0/PKG-INFO"
    tar -czf "$test_dir/aerospike-hello-3.0.0.tar.gz" -C "$test_dir" aerospike-hello-3.0.0/
    rm -rf "$test_dir/aerospike-hello-3.0.0"
    read -r -a meta < <(get_pypi_metadata "$test_dir/aerospike-hello-3.0.0.tar.gz")
    [[ "${meta[0]}" == "aerospike-hello" ]]
    [[ "${meta[1]}" == "3.0.0" ]]
    rm -rf "$test_dir"
}

# --- _validate_pypi_name ---

@test "_validate_pypi_name rejects name with semicolons (property injection)" {
    export DEPLOY_DIR
    run bash -c 'source "$DEPLOY_DIR/package_utils.sh" && _validate_pypi_name "evil;injected=bar"'
    [[ $status -ne 0 ]]
}

@test "_validate_pypi_name rejects name with spaces" {
    export DEPLOY_DIR
    run bash -c 'source "$DEPLOY_DIR/package_utils.sh" && _validate_pypi_name "has spaces"'
    [[ $status -ne 0 ]]
}

@test "_validate_pypi_name accepts valid Python package name" {
    _validate_pypi_name "aerospike-hello"
}

@test "_validate_pypi_name accepts name with dots and underscores" {
    _validate_pypi_name "My_Package.Name"
}

# --- _normalize_pypi_name ---

@test "_normalize_pypi_name lowercases and normalizes separators" {
    local result
    result=$(_normalize_pypi_name "My_Package.Name")
    [[ "$result" == "my-package-name" ]]
}

@test "_normalize_pypi_name handles already normalized names" {
    local result
    result=$(_normalize_pypi_name "aerospike-hello")
    [[ "$result" == "aerospike-hello" ]]
}

# --- is_go_module (type_detection.sh) ---

@test "is_go_module returns true for Go module zip" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/github.com/test/mod@v1.0.0"
    echo "module github.com/test/mod" > "$test_dir/github.com/test/mod@v1.0.0/go.mod"
    echo "package mod" > "$test_dir/github.com/test/mod@v1.0.0/mod.go"
    cd "$test_dir" && zip -q -r "gomod.zip" "github.com/" && cd - >/dev/null
    is_go_module "$test_dir/gomod.zip"
    rm -rf "$test_dir"
}

@test "is_go_module returns false for non-Go-module zip" {
    local test_dir
    test_dir=$(mktemp -d)
    echo "not a go module" > "$test_dir/data.txt"
    cd "$test_dir" && zip -q "plain.zip" "data.txt" && cd - >/dev/null
    rm -f "$test_dir/data.txt"
    run is_go_module "$test_dir/plain.zip"
    [[ $status -ne 0 ]]
    rm -rf "$test_dir"
}

# --- get_go_metadata ---

@test "get_go_metadata extracts module path and version" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/github.com/aerospike/mod@v2.1.0"
    echo "module github.com/aerospike/mod" > "$test_dir/github.com/aerospike/mod@v2.1.0/go.mod"
    cd "$test_dir" && zip -q -r "gomod.zip" "github.com/" && cd - >/dev/null
    read -r -a meta < <(get_go_metadata "$test_dir/gomod.zip")
    [[ "${meta[0]}" == "github.com/aerospike/mod" ]]
    [[ "${meta[1]}" == "v2.1.0" ]]
    rm -rf "$test_dir"
}

# --- _validate_go_module_path ---

@test "_validate_go_module_path rejects path with semicolons (property injection)" {
    export DEPLOY_DIR
    run bash -c 'source "$DEPLOY_DIR/package_utils.sh" && _validate_go_module_path "evil;injected=bar"'
    [[ $status -ne 0 ]]
}

@test "_validate_go_module_path rejects path without domain dot" {
    export DEPLOY_DIR
    run bash -c 'source "$DEPLOY_DIR/package_utils.sh" && _validate_go_module_path "noDomain/pkg"'
    [[ $status -ne 0 ]]
}

@test "_validate_go_module_path accepts valid Go module path" {
    _validate_go_module_path "github.com/aerospike/aeromod"
}

# --- is_helm_chart (type_detection.sh) ---

@test "is_helm_chart returns true for packaged Helm chart" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/mychart"
    cat > "$test_dir/mychart/Chart.yaml" <<'YAML'
apiVersion: v2
name: mychart
version: 0.1.0
YAML
    tar -czf "$test_dir/mychart-0.1.0.tgz" -C "$test_dir" mychart/
    rm -rf "$test_dir/mychart"
    is_helm_chart "$test_dir/mychart-0.1.0.tgz"
    rm -rf "$test_dir"
}

@test "is_helm_chart accepts apiVersion v1" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/oldchart"
    cat > "$test_dir/oldchart/Chart.yaml" <<'YAML'
apiVersion: v1
name: oldchart
version: 0.0.1
YAML
    tar -czf "$test_dir/oldchart-0.0.1.tgz" -C "$test_dir" oldchart/
    rm -rf "$test_dir/oldchart"
    is_helm_chart "$test_dir/oldchart-0.0.1.tgz"
    rm -rf "$test_dir"
}

@test "is_helm_chart returns false for npm tarball" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/package"
    echo '{"name":"foo","version":"1.0.0"}' > "$test_dir/package/package.json"
    tar -czf "$test_dir/foo-1.0.0.tgz" -C "$test_dir" package/
    rm -rf "$test_dir/package"
    run is_helm_chart "$test_dir/foo-1.0.0.tgz"
    [[ $status -ne 0 ]]
    rm -rf "$test_dir"
}

@test "is_helm_chart returns false for plain tarball" {
    local test_dir
    test_dir=$(mktemp -d)
    echo "plain content" > "$test_dir/data.txt"
    tar -czf "$test_dir/plain.tgz" -C "$test_dir" data.txt
    rm -f "$test_dir/data.txt"
    run is_helm_chart "$test_dir/plain.tgz"
    [[ $status -ne 0 ]]
    rm -rf "$test_dir"
}

@test "is_helm_chart returns false when Chart.yaml has no apiVersion" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/badchart"
    cat > "$test_dir/badchart/Chart.yaml" <<'YAML'
name: badchart
version: 0.0.1
YAML
    tar -czf "$test_dir/badchart-0.0.1.tgz" -C "$test_dir" badchart/
    rm -rf "$test_dir/badchart"
    run is_helm_chart "$test_dir/badchart-0.0.1.tgz"
    [[ $status -ne 0 ]]
    rm -rf "$test_dir"
}

# --- get_helm_metadata ---

@test "get_helm_metadata extracts name and version from packaged chart" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/aerospike-vector-search"
    cat > "$test_dir/aerospike-vector-search/Chart.yaml" <<'YAML'
apiVersion: v2
name: aerospike-vector-search
description: AVS chart
type: application
version: 0.0.1
appVersion: "0.0.1"
YAML
    tar -czf "$test_dir/aerospike-vector-search-0.0.1.tgz" -C "$test_dir" aerospike-vector-search/
    rm -rf "$test_dir/aerospike-vector-search"
    read -r -a meta < <(get_helm_metadata "$test_dir/aerospike-vector-search-0.0.1.tgz")
    [[ "${meta[0]}" == "aerospike-vector-search" ]]
    [[ "${meta[1]}" == "0.0.1" ]]
    rm -rf "$test_dir"
}

@test "get_helm_metadata strips quotes from version field" {
    local test_dir
    test_dir=$(mktemp -d)
    mkdir -p "$test_dir/quoted"
    cat > "$test_dir/quoted/Chart.yaml" <<'YAML'
apiVersion: v2
name: quoted
version: "2.5.0"
YAML
    tar -czf "$test_dir/quoted-2.5.0.tgz" -C "$test_dir" quoted/
    rm -rf "$test_dir/quoted"
    read -r -a meta < <(get_helm_metadata "$test_dir/quoted-2.5.0.tgz")
    [[ "${meta[0]}" == "quoted" ]]
    [[ "${meta[1]}" == "2.5.0" ]]
    rm -rf "$test_dir"
}

# --- _validate_helm_name ---

@test "_validate_helm_name rejects name with semicolons (property injection)" {
    export DEPLOY_DIR
    run bash -c 'source "$DEPLOY_DIR/package_utils.sh" && _validate_helm_name "evil;injected=bar"'
    [[ $status -ne 0 ]]
}

@test "_validate_helm_name rejects uppercase names" {
    export DEPLOY_DIR
    run bash -c 'source "$DEPLOY_DIR/package_utils.sh" && _validate_helm_name "BadName"'
    [[ $status -ne 0 ]]
}

@test "_validate_helm_name rejects name with spaces" {
    export DEPLOY_DIR
    run bash -c 'source "$DEPLOY_DIR/package_utils.sh" && _validate_helm_name "has spaces"'
    [[ $status -ne 0 ]]
}

@test "_validate_helm_name accepts hyphenated lowercase name" {
    _validate_helm_name "aerospike-vector-search"
}

@test "_validate_helm_name accepts name with dots" {
    _validate_helm_name "my.chart"
}
