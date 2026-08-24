
#!/usr/bin/env bats
# Tests for the manifest system: verifies that structuring writes correct
# manifest entries and that upload functions can read them.

load '../helpers/setup'

setup() {
    setup_test_artifacts
}

teardown() {
    teardown_test_artifacts
}

# Helper: run entrypoint and return manifest contents
get_manifest() {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    cat structured_build_artifacts/.manifest
}

@test "manifest file is created during structuring" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    [[ -f structured_build_artifacts/.manifest ]]
}

@test "manifest contains entries for deb files" {
    local manifest
    manifest=$(get_manifest)
    echo "$manifest" | grep -q $'\tdeb$'
}

@test "manifest contains entries for rpm files" {
    local manifest
    manifest=$(get_manifest)
    echo "$manifest" | grep -q $'\trpm$'
}

@test "manifest contains entries for jar files" {
    local manifest
    manifest=$(get_manifest)
    echo "$manifest" | grep -q $'\tjar$'
}

@test "manifest contains entries for nupkg files" {
    local manifest
    manifest=$(get_manifest)
    echo "$manifest" | grep -q $'\tnupkg$'
}

@test "manifest contains entries for snupkg files" {
    local manifest
    manifest=$(get_manifest)
    echo "$manifest" | grep -q $'\tsnupkg$'
}

@test "manifest contains entries for npm files" {
    local manifest
    manifest=$(get_manifest)
    echo "$manifest" | grep -q $'\tnpm$'
}

@test "manifest contains entries for pypi files" {
    local manifest
    manifest=$(get_manifest)
    echo "$manifest" | grep -q $'\tpypi$'
}

@test "manifest contains entries for generic files" {
    local manifest
    manifest=$(get_manifest)
    echo "$manifest" | grep -q $'\tgeneric$'
}

@test "manifest paths point to files that exist in structured_build_artifacts" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local missing=0
    while IFS=$'\t' read -r path type; do
        if [[ ! -f "$path" ]]; then
            echo "Missing: $path (type: $type)" >&2
            missing=$((missing + 1))
        fi
    done < structured_build_artifacts/.manifest
    [[ $missing -eq 0 ]]
}

@test "manifest does not contain companion files" {
    local manifest
    manifest=$(get_manifest)
    # Companion suffixes are .asc / .md5 / .sha1 / .module. Bare .pom is a
    # primary for standalone POMs (BOM/parent releases) so it is intentionally
    # not excluded — process_jar handles JAR-companion POMs without
    # manifesting them, and structure_standalone_poms manifests JAR-less POMs
    # as primaries. Gradle .module is always a stem-based companion of jar/pom
    # and is never a manifest primary.
    ! echo "$manifest" | grep -qE '\.(asc|md5|sha1|module)([[:space:]]|$)'
}

# --- Content detection tests ---
# These verify that ambiguous extensions (.tgz, .tar.gz) are routed to the
# correct type based on file contents, not just extension.

@test "npm .tgz with package.json is detected as npm" {
    local manifest
    manifest=$(get_manifest)
    echo "$manifest" | grep "aerospike-test-package-1.0.0.tgz" | grep -q $'\tnpm$'
}

@test "npm .tar.gz with package.json is detected as npm" {
    local manifest
    manifest=$(get_manifest)
    echo "$manifest" | grep "aerospike-targz-package-3.0.0.tar.gz" | grep -q $'\tnpm$'
}

@test "pypi sdist .tar.gz with PKG-INFO is detected as pypi" {
    local manifest
    manifest=$(get_manifest)
    echo "$manifest" | grep "aerospike-hello-1.0.0.tar.gz" | grep -q $'\tpypi$'
}

@test "pypi sdist .tgz with PKG-INFO is detected as pypi" {
    local manifest
    manifest=$(get_manifest)
    echo "$manifest" | grep "aerospike-utils-2.0.0.tgz" | grep -q $'\tpypi$'
}

@test "generic .tgz without package.json or PKG-INFO is detected as generic" {
    local manifest
    manifest=$(get_manifest)
    echo "$manifest" | grep "generic-archive.tgz" | grep -q $'\tgeneric$'
}

@test "generic .tar.gz without package.json or PKG-INFO is detected as generic" {
    local manifest
    manifest=$(get_manifest)
    echo "$manifest" | grep "test.tar.gz" | grep -q $'\tgeneric$'
}

# --- Completeness tests ---

@test "every structured primary file has a manifest entry" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local manifest_paths
    manifest_paths=$(cut -f1 structured_build_artifacts/.manifest | sort)

    # Find all primary files (exclude companions).
    # .md5/.sha1 are Maven sidecar checksums copied alongside the JAR by
    # process_jar; .module is Gradle Module Metadata (same stem as jar/pom).
    # They're companions, not primaries, and the upload step routes them off
    # the manifest path.
    local structured_files
    structured_files=$(find structured_build_artifacts -type f \
        -not -name "*.asc" \
        -not -name "*.pom" \
        -not -name "*.pom.asc" \
        -not -name "*.module" \
        -not -name "*.prov" \
        -not -name "*.md5" \
        -not -name "*.sha1" \
        -not -name "*.csproj" \
        -not -name ".manifest" \
        | sort)

    # Every structured file should appear in the manifest
    # Normalize paths: strip ./ prefix and collapse double slashes
    local normalized_manifest
    normalized_manifest=$(echo "$manifest_paths" | sed -e 's|^\./||' -e 's|//|/|g')
    local missing=0
    while IFS= read -r file; do
        local base normalized
        base=$(basename "$file")
        # Sidecar JSON from detect_types (not a deployable primary); not listed in .manifest
        if [[ "$base" == .*bundle-metadata.json ]]; then
            continue
        fi
        normalized="${file#./}"
        if ! echo "$normalized_manifest" | grep -qF "$normalized"; then
            echo "Not in manifest: $file" >&2
            missing=$((missing + 1))
        fi
    done <<< "$structured_files"
    [[ $missing -eq 0 ]]
}
