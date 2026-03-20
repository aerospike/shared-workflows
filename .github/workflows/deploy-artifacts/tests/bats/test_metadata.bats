#!/usr/bin/env bats
# Unit tests for metadata extraction functions in package_utils.sh
# These test functions in isolation without running the full entrypoint.

GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts"

setup() {
    source "$DEPLOY_DIR/package_utils.sh"
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
