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
