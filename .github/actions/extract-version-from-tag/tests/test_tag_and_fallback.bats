#!/usr/bin/env bats
# Tests for git tag extraction and fallback behavior

GIT_ROOT="$(git rev-parse --show-toplevel)"
HELPERS_DIR="$GIT_ROOT/.github/actions/extract-version-from-tag/tests/helpers"
load "$HELPERS_DIR/setup.bash"

setup() {
    reset_inputs
    setup_test_dir
    # Point VERSION_FILE to nonexistent path so file source is skipped
    VERSION_FILE="$TEST_TMPDIR/nonexistent"
}

teardown() {
    teardown_test_dir
}

@test "extracts version from GITHUB_REF tag" {
    GITHUB_REF="refs/tags/v1.0.0"

    resolve_version
    [ "$VERSION" = "1.0.0" ]
    [ "$SOURCE" = "tag" ]
    [ "$GIT_TAG" = "v1.0.0" ]
}

@test "tag without prefix passes through unchanged" {
    GITHUB_REF="refs/tags/1.0.0"

    resolve_version
    [ "$VERSION" = "1.0.0" ]
}

@test "tag with pre-release suffix" {
    GITHUB_REF="refs/tags/v1.0.0-rc.2"

    resolve_version
    [ "$VERSION" = "1.0.0-rc.2" ]
    [ "$SOURCE" = "tag" ]
}

@test "custom tag prefix is stripped" {
    TAG_PREFIX="release-"
    GITHUB_REF="refs/tags/release-2.0.0"

    resolve_version
    [ "$VERSION" = "2.0.0" ]
}

@test "non-tag GITHUB_REF falls through to fallback" {
    GITHUB_REF="refs/heads/feature-branch"

    resolve_version
    [ "$SOURCE" = "fallback" ]
    [ -n "$VERSION" ]
}

@test "empty GITHUB_REF falls through to fallback" {
    GITHUB_REF=""

    resolve_version
    [ "$SOURCE" = "fallback" ]
    [ -n "$VERSION" ]
}

@test "fallback produces non-empty version in repo with tags" {
    GITHUB_REF=""

    resolve_version
    [ "$SOURCE" = "fallback" ]
    [ -n "$VERSION" ]
    [ -n "$GIT_TAG" ]
}
