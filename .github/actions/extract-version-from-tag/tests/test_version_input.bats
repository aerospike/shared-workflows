#!/usr/bin/env bats
# Tests for explicit version input (highest priority)

GIT_ROOT="$(git rev-parse --show-toplevel)"
HELPERS_DIR="$GIT_ROOT/.github/actions/extract-version-from-tag/tests/helpers"
load "$HELPERS_DIR/setup.bash"

setup() {
    reset_inputs
    setup_test_dir
}

teardown() {
    teardown_test_dir
}

@test "explicit version takes highest priority over VERSION file" {
    VERSION_INPUT="2.0.0"
    echo "1.0.0" > "$TEST_TMPDIR/VERSION"
    VERSION_FILE="$TEST_TMPDIR/VERSION"

    resolve_version
    [ "$VERSION" = "2.0.0" ]
    [ "$SOURCE" = "input" ]
}

@test "explicit version takes highest priority over git tag" {
    VERSION_INPUT="2.0.0"
    GITHUB_REF="refs/tags/v9.0.0"

    resolve_version
    [ "$VERSION" = "2.0.0" ]
    [ "$SOURCE" = "input" ]
}

@test "semver pre-release: dev suffix" {
    VERSION_INPUT="1.0.0-dev"

    resolve_version
    [ "$VERSION" = "1.0.0-dev" ]
    [ "$SOURCE" = "input" ]
}

@test "semver pre-release: rc" {
    VERSION_INPUT="1.0.0-rc.1"

    resolve_version
    [ "$VERSION" = "1.0.0-rc.1" ]
    [ "$SOURCE" = "input" ]
}

@test "semver pre-release: alpha" {
    VERSION_INPUT="1.0.0-alpha.1"

    resolve_version
    [ "$VERSION" = "1.0.0-alpha.1" ]
    [ "$SOURCE" = "input" ]
}

@test "semver pre-release: SNAPSHOT" {
    VERSION_INPUT="1.0.0-SNAPSHOT"

    resolve_version
    [ "$VERSION" = "1.0.0-SNAPSHOT" ]
    [ "$SOURCE" = "input" ]
}

@test "prefix is stripped from explicit version" {
    VERSION_INPUT="v3.0.0"

    resolve_version
    [ "$VERSION" = "3.0.0" ]
    [ "$GIT_TAG" = "v3.0.0" ]
}

@test "custom prefix is stripped from explicit version" {
    VERSION_INPUT="release-3.0.0"
    TAG_PREFIX="release-"

    resolve_version
    [ "$VERSION" = "3.0.0" ]
    [ "$GIT_TAG" = "release-3.0.0" ]
}

@test "empty version input falls through to next source" {
    VERSION_INPUT=""
    echo "1.5.0" > "$TEST_TMPDIR/VERSION"
    VERSION_FILE="$TEST_TMPDIR/VERSION"

    resolve_version
    [ "$VERSION" = "1.5.0" ]
    [ "$SOURCE" = "file" ]
}
