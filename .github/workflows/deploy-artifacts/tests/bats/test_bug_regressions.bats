#!/usr/bin/env bats
# Regression tests for production bugs found in run 23078325637.
# These tests ensure the three confirmed bugs never regress.

load '../helpers/setup'
load '../helpers/command_parsers'

setup() {
    setup_test_artifacts
}

teardown() {
    teardown_test_artifacts
}

# --- Bug 1: .asc signatures silently dropped ---
# The sign stage creates .asc files but they were never uploaded to Artifactory.

@test "Bug 1: DEB .asc signature appears in upload commands" {
    local output
    output=$(run_entrypoint_dry_run)
    # The dry-run output should contain an upload command for the .asc file
    [[ "$output" == *"test-ubuntu22.04.deb.asc"* ]]
}

@test "Bug 1: RPM .asc signature appears in upload commands" {
    local output
    output=$(run_entrypoint_dry_run)
    [[ "$output" == *"test-1.0-2.noarch.rpm.asc"* ]]
}

@test "Bug 1: DEB .asc is structured alongside its parent" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local deb_dir
    deb_dir=$(find structured_build_artifacts/deb -name "test-ubuntu22.04.deb" -printf '%h\n' 2>/dev/null | head -1)
    [[ -n "$deb_dir" ]]
    [[ -f "$deb_dir/test-ubuntu22.04.deb.asc" ]]
}

@test "Bug 1: RPM .asc is structured alongside its parent" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local rpm_dir
    rpm_dir=$(find structured_build_artifacts/rpm -name "test-1.0-2.noarch.rpm" -printf '%h\n' 2>/dev/null | head -1)
    [[ -n "$rpm_dir" ]]
    [[ -f "$rpm_dir/test-1.0-2.noarch.rpm.asc" ]]
}

# --- Bug 2: Generic paths leak unsigned-artifacts/ prefix ---
# The sign stage creates signed-artifacts/unsigned-artifacts/... which
# deploy receives as build-artifacts/unsigned-artifacts/...
# This prefix should not appear in Artifactory paths.

@test "Bug 2: generic structured files have no unsigned-artifacts prefix" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    [[ -f "structured_build_artifacts/generic/net8.0/app.dll" ]]
    [[ ! -d "structured_build_artifacts/generic/unsigned-artifacts" ]]
}

@test "Bug 2: generic upload commands have no unsigned-artifacts in path" {
    local output
    output=$(run_entrypoint_dry_run)
    local upload_cmds
    upload_cmds=$(echo "$output" | grep -E "jf rt upload.*generic-dev-local" || true)
    if [[ -n "$upload_cmds" ]]; then
        # None of the generic upload commands should contain "unsigned-artifacts"
        [[ "$upload_cmds" != *"unsigned-artifacts"* ]]
    fi
}

# --- Bug 3: Generic uploads have no metadata properties ---
# DEB/RPM get version and distribution properties. Generic had nothing.

@test "Bug 3: generic uploads include version in target-props" {
    local output
    output=$(run_entrypoint_dry_run)
    local generic_cmds
    generic_cmds=$(echo "$output" | grep -E "jf rt upload.*generic-dev-local" || true)
    if [[ -n "$generic_cmds" ]]; then
        [[ "$generic_cmds" == *"version="* ]]
    fi
}
