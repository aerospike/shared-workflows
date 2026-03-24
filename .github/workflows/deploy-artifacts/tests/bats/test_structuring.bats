#!/usr/bin/env bats
# Tests for artifact structuring: correct routing, companion gathering, path handling.

load '../helpers/setup'

setup() {
    setup_test_artifacts
}

teardown() {
    teardown_test_artifacts
}

@test "DEB .asc companion is co-located with primary after structuring" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    # The DEB should be structured into pool/{codename}/{pkg}/
    local deb_dir
    deb_dir=$(find structured_build_artifacts/deb -name "test-ubuntu22.04.deb" -printf '%h\n' 2>/dev/null | head -1)
    [[ -n "$deb_dir" ]]
    # The .asc companion should be in the same directory
    [[ -f "$deb_dir/test-ubuntu22.04.deb.asc" ]]
}

@test "RPM .asc companion is co-located with primary after structuring" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local rpm_dir
    rpm_dir=$(find structured_build_artifacts/rpm -name "test-1.0-2.noarch.rpm" -printf '%h\n' 2>/dev/null | head -1)
    [[ -n "$rpm_dir" ]]
    [[ -f "$rpm_dir/test-1.0-2.noarch.rpm.asc" ]]
}

@test "NuGet .asc companion is co-located with primary after structuring" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local nupkg_dir
    nupkg_dir=$(find structured_build_artifacts/nupkg -name "Aerospike.Client.8.0.2.nupkg" -printf '%h\n' 2>/dev/null | head -1)
    [[ -n "$nupkg_dir" ]]
    [[ -f "$nupkg_dir/Aerospike.Client.8.0.2.nupkg.asc" ]]
}

@test "Generic files have unsigned-artifacts prefix stripped" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    [[ -f "structured_build_artifacts/generic/net8.0/app.dll" ]]
    [[ ! -d "structured_build_artifacts/generic/unsigned-artifacts" ]]
}

@test "No .nupkg files leak into generic structured dir" {
    # NuGet packages should be in nupkg/, never in generic/
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local nupkg_count
    nupkg_count=$(find structured_build_artifacts/generic -name "*.nupkg" 2>/dev/null | wc -l)
    [[ "$nupkg_count" -eq 0 ]]
}

@test "All standard type directories are created" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    [[ -d "structured_build_artifacts/deb" ]]
    [[ -d "structured_build_artifacts/rpm" ]]
    [[ -d "structured_build_artifacts/jar" ]]
    [[ -d "structured_build_artifacts/nupkg" ]]
    [[ -d "structured_build_artifacts/npm" ]]
    [[ -d "structured_build_artifacts/generic" ]]
}

@test "scoped npm .tgz with package.json routes to npm dir" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    [[ -f "structured_build_artifacts/npm/aerospike-test-package-1.0.0.tgz" ]]
}

@test "unscoped npm .tgz with package.json routes to npm dir" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    [[ -f "structured_build_artifacts/npm/aerospike-6.0.0.tgz" ]]
}

@test "npm .asc companion is co-located with scoped primary after structuring" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local npm_dir
    npm_dir=$(find structured_build_artifacts/npm -name "aerospike-test-package-1.0.0.tgz" -printf '%h\n' 2>/dev/null | head -1)
    [[ -n "$npm_dir" ]]
    [[ -f "$npm_dir/aerospike-test-package-1.0.0.tgz.asc" ]]
}

@test "npm .asc companion is co-located with unscoped primary after structuring" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local npm_dir
    npm_dir=$(find structured_build_artifacts/npm -name "aerospike-6.0.0.tgz" -printf '%h\n' 2>/dev/null | head -1)
    [[ -n "$npm_dir" ]]
    [[ -f "$npm_dir/aerospike-6.0.0.tgz.asc" ]]
}

@test "non-npm .tgz routes to generic, not npm" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    # generic-archive.tgz has no package/package.json, so it should be in generic
    [[ -f "structured_build_artifacts/generic/generic-archive.tgz" ]]
    # And NOT in npm
    local npm_generic_count
    npm_generic_count=$(find structured_build_artifacts/npm -name "generic-archive.tgz" 2>/dev/null | wc -l)
    [[ "$npm_generic_count" -eq 0 ]]
}

@test "No npm .tgz files leak into generic structured dir" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local npm_in_generic
    npm_in_generic=$(find structured_build_artifacts/generic -name "aerospike-test-package-*.tgz" 2>/dev/null | wc -l)
    [[ "$npm_in_generic" -eq 0 ]]
}
