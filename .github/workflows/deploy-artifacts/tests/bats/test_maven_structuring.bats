#!/usr/bin/env bats
# Maven structuring: detect_types and full pipeline (JFrog repo layout).

load '../helpers/setup'
load '../helpers/maven_fixtures'

setup() {
    local _base="${BATS_TEST_TMPDIR:-${BATS_TMPDIR:-${TMPDIR:-/tmp}}}"
    mkdir -p "$_base"
    MAVEN_STRUCT_TEST_DIR=$(mktemp -d "${_base%/}/maven-struct.XXXXXX")
    export MAVEN_STRUCT_TEST_DIR
}

teardown() {
    if [[ -n ${MAVEN_STRUCT_TEST_DIR:-} && -d ${MAVEN_STRUCT_TEST_DIR} ]]; then
        rm -rf "${MAVEN_STRUCT_TEST_DIR}"
    fi
    unset MAVEN_STRUCT_TEST_DIR || true
}

# --- detect_types only ---

@test "detect_types: jar+pom sibling structures POM to GAV with .pom.asc" {
    require_bash4_for_detect_types
    local wd="$MAVEN_STRUCT_TEST_DIR/wd"
    create_jfrog_maven_fixture_tree "$wd"
    run_detect_types_in "$wd"

    local target="$wd/structured_build_artifacts/jar/com/example/app/my-app/1.0.0"
    [[ -f "$target/my-app-1.0.0.pom" ]]
    [[ -f "$target/my-app-1.0.0.pom.asc" ]]
    [[ ! -f "$target/my-app-1.0.0.jar" ]]
}

@test "detect_types: parent aggregator (no jar) structures as standalone POM" {
    require_bash4_for_detect_types
    local wd="$MAVEN_STRUCT_TEST_DIR/wd"
    create_jfrog_maven_fixture_tree "$wd"
    run_detect_types_in "$wd"

    local target="$wd/structured_build_artifacts/jar/com/example/parent/parent-proj/1.0.0"
    [[ -f "$target/parent-proj-1.0.0.pom" ]]
    [[ -f "$target/parent-proj-1.0.0.pom.asc" ]]
}

@test "detect_types: child with parent resolves to child GAV path" {
    require_bash4_for_detect_types
    local wd="$MAVEN_STRUCT_TEST_DIR/wd"
    create_jfrog_maven_fixture_tree "$wd"
    run_detect_types_in "$wd"

    local target="$wd/structured_build_artifacts/jar/com/example/parent/child-one/1.0.0"
    [[ -f "$target/child-one-1.0.0.pom" ]]
    [[ -f "$target/child-one-1.0.0.pom.asc" ]]
    [[ ! -f "$wd/structured_build_artifacts/jar/com/example/parent/parent-proj/1.0.0/child-one-1.0.0.pom" ]]
}

@test "detect_types: all five POMs appear in manifest as jar type" {
    require_bash4_for_detect_types
    local wd="$MAVEN_STRUCT_TEST_DIR/wd" manifest
    create_jfrog_maven_fixture_tree "$wd"
    run_detect_types_in "$wd"

    manifest="$wd/structured_build_artifacts/.manifest"
    for pom in \
        standalone-bom-2.1.0.pom \
        my-app-1.0.0.pom \
        parent-proj-1.0.0.pom \
        child-two-1.0.0.pom \
        child-one-1.0.0.pom; do
        grep -qE "${pom}[[:space:]]+jar$" "$manifest" || \
            (echo "Missing manifest entry for $pom:" >&2 && cat "$manifest" >&2 && return 1)
    done
    [[ "$(wc -l <"$manifest" | tr -d ' ')" == "5" ]]
}

@test "detect_types: JAR files are not copied during detection" {
    require_bash4_for_detect_types
    local wd="$MAVEN_STRUCT_TEST_DIR/wd" jar_count
    create_jfrog_maven_fixture_tree "$wd"
    run_detect_types_in "$wd"

    jar_count=$(find "$wd/structured_build_artifacts" -name '*.jar' 2>/dev/null | wc -l | tr -d ' ')
    [[ "$jar_count" -eq 0 ]]
}

# --- full pipeline (shared maven-repo fixtures from create-test-fixtures.sh) ---

@test "deploy: jar+pom bundle lands under GAV with jar and all sidecars" {
    setup_test_artifacts
    run_entrypoint_dry_run >/dev/null 2>&1 || true

    local target="structured_build_artifacts/jar/com/example/app/my-app/1.0.0"
    for f in my-app-1.0.0.jar my-app-1.0.0.pom \
             my-app-1.0.0.jar.asc my-app-1.0.0.pom.asc; do
        [[ -f "$target/$f" ]] || (echo "Missing $target/$f" >&2 && return 1)
    done
}

@test "deploy: parent aggregator and two children structured under correct GAV paths" {
    setup_test_artifacts
    run_entrypoint_dry_run >/dev/null 2>&1 || true

    local parent="structured_build_artifacts/jar/com/example/parent/parent-proj/1.0.0"
    [[ -f "$parent/parent-proj-1.0.0.pom" ]]
    [[ -f "$parent/parent-proj-1.0.0.pom.asc" ]]

    local child1="structured_build_artifacts/jar/com/example/parent/child-one/1.0.0"
    local child2="structured_build_artifacts/jar/com/example/parent/child-two/1.0.0"
    for f in child-one-1.0.0.jar child-one-1.0.0.pom child-one-1.0.0.jar.asc child-one-1.0.0.pom.asc; do
        [[ -f "$child1/$f" ]] || (echo "Missing $child1/$f" >&2 && return 1)
    done
    for f in child-two-1.0.0.jar child-two-1.0.0.pom child-two-1.0.0.jar.asc child-two-1.0.0.pom.asc; do
        [[ -f "$child2/$f" ]] || (echo "Missing $child2/$f" >&2 && return 1)
    done
}
