#!/usr/bin/env bats
# Rust crate structuring via detect_types.sh (detect-only path for artifact-publisher).

load '../helpers/setup'
load '../helpers/maven_fixtures'
load '../helpers/crate_fixtures'

setup() {
    local _base="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}"
    mkdir -p "$_base"
    CRATE_DETECT_TEST_DIR=$(mktemp -d "${_base%/}/crate-detect.XXXXXX")
    export CRATE_DETECT_TEST_DIR
}

teardown() {
    if [[ -n ${CRATE_DETECT_TEST_DIR:-} && -d ${CRATE_DETECT_TEST_DIR} ]]; then
        rm -rf "${CRATE_DETECT_TEST_DIR}"
    fi
    unset CRATE_DETECT_TEST_DIR || true
}

@test "detect_types: valid crate routes to crate dir with .asc companion" {
    require_bash4_for_detect_types
    local wd="$CRATE_DETECT_TEST_DIR/wd-flat"
    create_crate_fixture_tree "$wd"
    run_detect_types_in "$wd"

    local crate_dir="$wd/structured_build_artifacts/crate"
    [[ -f "$crate_dir/aerospike-3.0.0-alpha.1.crate" ]]
    [[ -f "$crate_dir/aerospike-3.0.0-alpha.1.crate.asc" ]]

    local generic_crate_count
    generic_crate_count=$(find "$wd/structured_build_artifacts/generic" -name '*.crate' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$generic_crate_count" -eq 0 ]]
}

@test "detect_types: RBV2 nested layout structures crate from deep path" {
    require_bash4_for_detect_types
    local wd="$CRATE_DETECT_TEST_DIR/wd-nested"
    create_jfrog_crate_fixture_tree "$wd"
    run_detect_types_in "$wd"

    local crate_file="$wd/structured_build_artifacts/crate/database-generic-prod-public-local/ci-build/v1.0.0/aerospike-3.0.0-alpha.1.crate"
    local asc_file="$wd/structured_build_artifacts/crate/database-generic-prod-public-local/ci-build/v1.0.0/aerospike-3.0.0-alpha.1.crate.asc"
    [[ -f "$crate_file" ]]
    [[ -f "$asc_file" ]]
}

@test "detect_types: manifest lists crate type for valid .crate" {
    require_bash4_for_detect_types
    local wd="$CRATE_DETECT_TEST_DIR/wd-manifest" manifest
    create_crate_fixture_tree "$wd"
    run_detect_types_in "$wd"

    manifest="$wd/structured_build_artifacts/.manifest"
    grep -qE 'aerospike-3\.0\.0-alpha\.1\.crate[[:space:]]+crate$' "$manifest" || \
        (echo "Missing crate manifest entry:" >&2 && cat "$manifest" >&2 && return 1)
}

@test "detect_types: invalid .crate is not structured into crate or generic dirs" {
    require_bash4_for_detect_types
    local wd="$CRATE_DETECT_TEST_DIR/wd-invalid"
    create_crate_fixture_tree "$wd"
    run_detect_types_in "$wd"

    [[ ! -f "$wd/structured_build_artifacts/crate/invalid-fixture.crate" ]]
    [[ ! -f "$wd/structured_build_artifacts/generic/invalid-fixture.crate" ]]
}
