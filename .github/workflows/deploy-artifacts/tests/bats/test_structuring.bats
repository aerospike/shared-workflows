#!/usr/bin/env bats
# Tests for artifact structuring: correct routing, companion gathering, path handling.

load '../helpers/setup'
load '../helpers/command_parsers'

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
    rpm_dir=$(find structured_build_artifacts/rpm -name "test-1.0-2.el9.noarch.rpm" -printf '%h\n' 2>/dev/null | head -1)
    [[ -n "$rpm_dir" ]]
    [[ -f "$rpm_dir/test-1.0-2.el9.noarch.rpm.asc" ]]
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

@test "Architecture: all DEB is structured into deb dir with companion" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local deb_dir
    deb_dir=$(find structured_build_artifacts/deb -name "test-all-arch_1.0.0-1ubuntu22.04_all.deb" -printf '%h\n' 2>/dev/null | head -1)
    [[ -n "$deb_dir" ]]
    [[ -f "$deb_dir/test-all-arch_1.0.0-1ubuntu22.04_all.deb.asc" ]]
}

@test "Architecture: all DEB is structured under correct codename pool" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local deb_path
    deb_path=$(find structured_build_artifacts/deb -name "test-all-arch_1.0.0-1ubuntu22.04_all.deb" 2>/dev/null | head -1)
    [[ -n "$deb_path" ]]
    # Should be under pool/jammy/ (codename derived from ubuntu22.04 in filename)
    [[ "$deb_path" == *"/pool/jammy/"* ]]
}

@test "No .nupkg files leak into generic structured dir" {
    # NuGet packages should be in nupkg/, never in generic/
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local nupkg_count
    nupkg_count=$(find structured_build_artifacts/generic -name "*.nupkg" 2>/dev/null | wc -l)
    [[ "$nupkg_count" -eq 0 ]]
}

@test "Windows .exe .msi .msix route to win dir not generic; dry-run upload targets generic-dev-local" {
    local output
    output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

    [[ -f "structured_build_artifacts/win/ci-win-fixture.exe" ]]
    [[ -f "structured_build_artifacts/win/ci-win-fixture.msi" ]]
    [[ -f "structured_build_artifacts/win/ci-win-fixture.msix" ]]
    local generic_win_count
    generic_win_count=$(find structured_build_artifacts/generic \( -name "*.exe" -o -name "*.msi" -o -name "*.msix" \) 2>/dev/null | wc -l | tr -d ' ')
    [[ "$generic_win_count" -eq 0 ]]

    local cmds
    cmds=$(extract_upload_commands "$output")
    echo "$cmds" | grep -qF "ci-win-fixture.exe"
    echo "$cmds" | grep -qF "ci-win-fixture.msi"
    echo "$cmds" | grep -qF "ci-win-fixture.msix"
    echo "$cmds" | grep -qF "generic-dev-local"
    [[ "$cmds" != *win-dev-local* ]]
}

@test "All standard type directories are created" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    [[ -d "structured_build_artifacts/deb" ]]
    [[ -d "structured_build_artifacts/rpm" ]]
    [[ -d "structured_build_artifacts/jar" ]]
    [[ -d "structured_build_artifacts/nupkg" ]]
    [[ -d "structured_build_artifacts/npm" ]]
    [[ -d "structured_build_artifacts/pypi" ]]
    [[ -d "structured_build_artifacts/win" ]]
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

# --- PyPI structuring ---

@test "wheel .whl routes to pypi dir" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    [[ -f "structured_build_artifacts/pypi/aerospike_hello-1.0.0-py3-none-any.whl" ]]
}

@test "sdist .tar.gz with PKG-INFO routes to pypi dir" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    [[ -f "structured_build_artifacts/pypi/aerospike-hello-1.0.0.tar.gz" ]]
}

@test "pypi .asc companion is co-located with wheel after structuring" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local whl_dir
    whl_dir=$(find structured_build_artifacts/pypi -name "aerospike_hello-1.0.0-py3-none-any.whl" -printf '%h\n' 2>/dev/null | head -1)
    [[ -n "$whl_dir" ]]
    [[ -f "$whl_dir/aerospike_hello-1.0.0-py3-none-any.whl.asc" ]]
}

@test "pypi .asc companion is co-located with sdist after structuring" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local sdist_dir
    sdist_dir=$(find structured_build_artifacts/pypi -name "aerospike-hello-1.0.0.tar.gz" -printf '%h\n' 2>/dev/null | head -1)
    [[ -n "$sdist_dir" ]]
    [[ -f "$sdist_dir/aerospike-hello-1.0.0.tar.gz.asc" ]]
}

@test "non-sdist .tar.gz routes to generic, not pypi" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    # test.tar.gz has no PKG-INFO, so it should be in generic
    [[ -f "structured_build_artifacts/generic/test.tar.gz" ]]
    # And NOT in pypi
    local pypi_generic_count
    pypi_generic_count=$(find structured_build_artifacts/pypi -name "test.tar.gz" 2>/dev/null | wc -l)
    [[ "$pypi_generic_count" -eq 0 ]]
}

@test "No pypi .whl files leak into generic structured dir" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local whl_in_generic
    whl_in_generic=$(find structured_build_artifacts/generic -name "*.whl" 2>/dev/null | wc -l)
    [[ "$whl_in_generic" -eq 0 ]]
}

# --- Helm structuring ---

@test "Helm chart .tgz routes to helm dir" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local chart
    chart=$(find structured_build_artifacts/helm -name "aerospike-hello-0.4.2.tgz" 2>/dev/null | head -1)
    [[ -n "$chart" ]]
}

@test "Helm .prov companion is co-located with chart after structuring" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local chart_dir
    chart_dir=$(find structured_build_artifacts/helm -name "aerospike-hello-0.4.2.tgz" -printf '%h\n' 2>/dev/null | head -1)
    [[ -n "$chart_dir" ]]
    [[ -f "$chart_dir/aerospike-hello-0.4.2.tgz.prov" ]]
}

@test "No helm .tgz files leak into generic structured dir" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local helm_in_generic
    helm_in_generic=$(find structured_build_artifacts/generic -name "aerospike-hello-*.tgz" 2>/dev/null | wc -l)
    [[ "$helm_in_generic" -eq 0 ]]
}

# --- Maven / JAR structuring ---

@test "flat JAR routes to jar/GAV/ with pom and .asc companions co-located" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local jar_dir
    jar_dir="structured_build_artifacts/jar/com/example/test/test/1.0.0"
    [[ -f "$jar_dir/test.jar" ]]
    [[ -f "$jar_dir/test.pom" ]]
    [[ -f "$jar_dir/test.jar.asc" ]]
    [[ -f "$jar_dir/test.pom.asc" ]]
}

@test "nested JFrog-layout JAR routes to jar/GAV/ with pom and .asc co-located" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local jar_dir
    jar_dir="structured_build_artifacts/jar/com/example/app/my-app/1.0.0"
    [[ -f "$jar_dir/my-app-1.0.0.jar" ]]
    [[ -f "$jar_dir/my-app-1.0.0.pom" ]]
    [[ -f "$jar_dir/my-app-1.0.0.jar.asc" ]]
    [[ -f "$jar_dir/my-app-1.0.0.pom.asc" ]]
}

@test "flat standalone BOM routes to jar/GAV/ with pom.asc co-located" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local bom_dir
    bom_dir="structured_build_artifacts/jar/com/example/bom/standalone-bom/1.0.0"
    [[ -f "$bom_dir/standalone-bom.pom" ]]
    [[ -f "$bom_dir/standalone-bom.pom.asc" ]]
    [[ -f "$bom_dir/standalone-bom.pom.md5" ]]
    [[ -f "$bom_dir/standalone-bom.pom.sha1" ]]
}

@test "nested standalone BOM routes to jar/GAV/ with pom.asc co-located" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local bom_dir
    bom_dir="structured_build_artifacts/jar/com/example/bom/standalone-bom/2.1.0"
    [[ -f "$bom_dir/standalone-bom-2.1.0.pom" ]]
    [[ -f "$bom_dir/standalone-bom-2.1.0.pom.asc" ]]
}

@test "No .jar or .pom files leak into generic structured dir" {
    run_entrypoint_dry_run >/dev/null 2>&1 || true
    local jar_in_generic pom_in_generic
    jar_in_generic=$(find structured_build_artifacts/generic -name '*.jar' 2>/dev/null | wc -l | tr -d ' ')
    pom_in_generic=$(find structured_build_artifacts/generic -name '*.pom' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$jar_in_generic" -eq 0 ]]
    [[ "$pom_in_generic" -eq 0 ]]
}
