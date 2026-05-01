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

# --- Bug 1 & 4: .asc companion signatures must be uploaded for ALL types ---
# The sign stage creates .asc files alongside every artifact. These must appear in
# actual jf rt upload commands, not just structuring logs. This test is comprehensive:
# if a new type is added with .asc fixtures but no upload handling, it will fail.

@test "Every .asc fixture appears in a jf rt upload command" {
    local output
    output=$(run_entrypoint_dry_run)

    # Extract only actual upload commands (strip ANSI codes)
    local upload_cmds
    upload_cmds=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -E "jf rt upload" || true)

    # Find all .asc files in the fixture directory.
    # Exclude .md5.asc/.sha1.asc: Maven Central convention is that checksums
    # are not signed, so the deploy step intentionally drops them. They're
    # kept as fixtures for the negative-test cases in test_java_upload.bats.
    local missing=()
    while IFS= read -r -d '' asc_file; do
        local basename
        basename=$(basename "$asc_file")
        if ! echo "$upload_cmds" | grep -qF "$basename"; then
            missing+=("$basename")
        fi
    done < <(find "$BUILD_ARTIFACTS_DIR" -name "*.asc" \
        -not -name "*.md5.asc" -not -name "*.sha1.asc" -print0)

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "FAIL: .asc files not found in any upload command:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "Every .asc fixture is structured alongside its primary file" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true

    # Exclude .md5.asc/.sha1.asc: see comment in the previous test.
    local missing=()
    while IFS= read -r -d '' asc_file; do
        local basename
        basename=$(basename "$asc_file")
        # Search for the .asc in structured_build_artifacts
        if ! find structured_build_artifacts -name "$basename" -print -quit 2>/dev/null | grep -q .; then
            missing+=("$basename")
        fi
    done < <(find "$BUILD_ARTIFACTS_DIR" -name "*.asc" \
        -not -name "*.md5.asc" -not -name "*.sha1.asc" -print0)

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "FAIL: .asc files not found in structured_build_artifacts:" >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
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

# --- Bug 4: snupkg must be uploaded to nuget repo ---

@test "Bug 4: snupkg is uploaded to nuget repo" {
    local output
    output=$(run_entrypoint_dry_run)
    local snupkg_cmds
    snupkg_cmds=$(echo "$output" | sed 's/\x1b\[[0-9;]*m//g' | grep -E "jf rt upload.*\.snupkg[^.].*nuget-dev-local" || true)
    [[ -n "$snupkg_cmds" ]]
}
