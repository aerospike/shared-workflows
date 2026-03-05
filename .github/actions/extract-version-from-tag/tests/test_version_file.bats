#!/usr/bin/env bats
# Tests for VERSION file extraction

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

@test "reads version from VERSION file" {
    echo "1.2.3" > "$TEST_TMPDIR/VERSION"
    VERSION_FILE="$TEST_TMPDIR/VERSION"

    resolve_version
    [ "$VERSION" = "1.2.3" ]
    [ "$SOURCE" = "file" ]
}

@test "strips prefix from VERSION file content" {
    echo "v4.5.6" > "$TEST_TMPDIR/VERSION"
    VERSION_FILE="$TEST_TMPDIR/VERSION"

    resolve_version
    [ "$VERSION" = "4.5.6" ]
    [ "$GIT_TAG" = "v4.5.6" ]
}

@test "handles VERSION file with trailing whitespace and newlines" {
    printf "  1.0.0  \n" > "$TEST_TMPDIR/VERSION"
    VERSION_FILE="$TEST_TMPDIR/VERSION"

    resolve_version
    [ "$VERSION" = "1.0.0" ]
}

@test "semver pre-release in VERSION file accepted" {
    echo "2.0.0-beta.1" > "$TEST_TMPDIR/VERSION"
    VERSION_FILE="$TEST_TMPDIR/VERSION"

    resolve_version
    [ "$VERSION" = "2.0.0-beta.1" ]
}

@test "non-existent VERSION file falls through to tag" {
    VERSION_FILE="$TEST_TMPDIR/nonexistent"
    GITHUB_REF="refs/tags/v9.0.0"

    resolve_version
    [ "$VERSION" = "9.0.0" ]
    [ "$SOURCE" = "tag" ]
}

@test "empty VERSION file falls through to tag" {
    : > "$TEST_TMPDIR/VERSION"
    VERSION_FILE="$TEST_TMPDIR/VERSION"
    GITHUB_REF="refs/tags/v7.0.0"

    resolve_version
    [ "$VERSION" = "7.0.0" ]
    [ "$SOURCE" = "tag" ]
}
