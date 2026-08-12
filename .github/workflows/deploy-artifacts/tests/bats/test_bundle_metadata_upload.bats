#!/usr/bin/env bats
# Regression tests for Maven bundle metadata GitHub artifact upload handoff.
# upload-artifact ignores dotfiles unless include-hidden-files: true; the workflow
# integration test test_deploy-bundle-metadata-upload.yaml exercises the real upload.

load '../helpers/setup'

GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_WORKFLOW="$GIT_ROOT/.github/workflows/reusable_deploy-artifacts.yaml"
CHECKER="$GIT_ROOT/.github/workflows/deploy-artifacts/tests/check_bundle_metadata_upload_step.sh"

setup_file() {
    chmod +x "$CHECKER"
    chmod +x "$GIT_ROOT/.github/workflows/deploy-artifacts/create-maven-bundle-metadata-fixtures.sh"
}

# Mirrors Record bundle metadata artifact outputs in reusable_deploy-artifacts.yaml.
record_bundle_metadata_available() {
    local gh_upload="$1"
    local meta_path="$2"

    if [[ "$gh_upload" != "true" ]]; then
        echo "false"
        return 0
    fi
    if [[ ! -f "$meta_path" ]]; then
        echo "false"
        return 0
    fi
    local module_count
    module_count="$(jq -r '.maven_module_count // 0' "$meta_path")"
    if [[ "$module_count" -le 0 ]]; then
        echo "false"
        return 0
    fi
    echo "true"
}

@test "check_bundle_metadata_upload_step passes on reusable_deploy-artifacts.yaml" {
    run "$CHECKER" "$DEPLOY_WORKFLOW"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Bundle metadata upload step configuration is valid"* ]]
}

@test "check_bundle_metadata_upload_step rejects missing include-hidden-files" {
    local bad_file
    bad_file="$(mktemp "${BATS_TMPDIR:-/tmp}/bad-deploy-workflow.XXXXXX.yaml")"
    trap 'rm -f "$bad_file"' RETURN
    sed '/include-hidden-files: true/d' "$DEPLOY_WORKFLOW" >"$bad_file"

    run "$CHECKER" "$bad_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"include-hidden-files: true"* ]]
}

@test "check_bundle_metadata_upload_step rejects missing if-no-files-found error" {
    local bad_file
    bad_file="$(mktemp "${BATS_TMPDIR:-/tmp}/bad-deploy-workflow.XXXXXX.yaml")"
    trap 'rm -f "$bad_file"' RETURN
    sed '/if-no-files-found: error/d' "$DEPLOY_WORKFLOW" >"$bad_file"

    run "$CHECKER" "$bad_file"
    [ "$status" -ne 0 ]
    [[ "$output" == *"if-no-files-found: error"* ]]
}

@test "detect_types produces hidden dotfile that record step would accept" {
    ((BASH_VERSINFO[0] >= 4)) || skip "requires bash 4+ for detect_types (type_registry associative arrays)"

    local wd meta_path
    wd="$(mktemp -d "${BATS_TMPDIR:-/tmp}/bundle-upload.XXXXXX")"
    trap 'rm -rf "$wd"' RETURN

    mkdir -p "$wd/build-artifacts"
    cat >"$wd/build-artifacts/hello-world-1.0.0.pom" <<'POM'
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>hello-world</artifactId>
  <version>1.0.0</version>
  <packaging>jar</packaging>
</project>
POM
    echo "placeholder" >"$wd/build-artifacts/hello-world-1.0.0.jar"

    (cd "$wd" && "$DEPLOY_ARTIFACTS_DIR/detect_types.sh" --artifacts-dir build-artifacts >/dev/null)

    meta_path="$wd/structured_build_artifacts/.maven-bundle-metadata.json"
    [[ -f "$meta_path" ]]
    [[ "$(basename "$meta_path")" == .maven-bundle-metadata.json ]]
    [[ "$(jq -r '.maven_module_count' "$meta_path")" -gt 0 ]]

    cd "$wd"
    [[ -f "structured_build_artifacts/.maven-bundle-metadata.json" ]]
}

@test "record step logic skips upload when maven_module_count is zero" {
    ((BASH_VERSINFO[0] >= 4)) || skip "requires bash 4+ for detect_types (type_registry associative arrays)"

    local wd meta_path module_count
    wd="$(mktemp -d "${BATS_TMPDIR:-/tmp}/bundle-upload-zero.XXXXXX")"
    trap 'rm -rf "$wd"' RETURN

    mkdir -p "$wd/build-artifacts"
    (cd "$wd" && "$DEPLOY_ARTIFACTS_DIR/detect_types.sh" --artifacts-dir build-artifacts >/dev/null)

    meta_path="$wd/structured_build_artifacts/.maven-bundle-metadata.json"
    [[ -f "$meta_path" ]]
    module_count="$(jq -r '.maven_module_count // 0' "$meta_path")"
    [[ "$module_count" -eq 0 ]]

    # Mirrors Record bundle metadata artifact outputs when no Maven modules were found.
    [[ "$module_count" -le 0 ]]
    [[ "$(record_bundle_metadata_available true "$meta_path")" == "false" ]]
}

@test "record step sets available false when gh-upload-bundle-metadata is false" {
    local wd meta_path
    wd="$(mktemp -d "${BATS_TMPDIR:-/tmp}/bundle-upload-disabled.XXXXXX")"
    trap 'rm -rf "$wd"' RETURN

    "$GIT_ROOT/.github/workflows/deploy-artifacts/create-maven-bundle-metadata-fixtures.sh" "$wd/fixtures"
    ((BASH_VERSINFO[0] >= 4)) || skip "requires bash 4+ for detect_types (type_registry associative arrays)"
    mkdir -p "$wd/build-artifacts"
    cp "$wd/fixtures/"*.pom "$wd/fixtures/"*.jar "$wd/build-artifacts/"
    (cd "$wd" && "$DEPLOY_ARTIFACTS_DIR/detect_types.sh" --artifacts-dir build-artifacts >/dev/null)

    meta_path="$wd/structured_build_artifacts/.maven-bundle-metadata.json"
    [[ -f "$meta_path" ]]
    [[ "$(record_bundle_metadata_available false "$meta_path")" == "false" ]]
}

@test "minimal maven fixture script produces deployable Maven artifacts" {
    local wd
    wd="$(mktemp -d "${BATS_TMPDIR:-/tmp}/minimal-fixtures.XXXXXX")"
    trap 'rm -rf "$wd"' RETURN

    "$GIT_ROOT/.github/workflows/deploy-artifacts/create-maven-bundle-metadata-fixtures.sh" "$wd/fixtures"
    [[ -f "$wd/fixtures/hello-world-1.0.0.pom" ]]
    [[ -f "$wd/fixtures/hello-world-1.0.0.jar" ]]
}
