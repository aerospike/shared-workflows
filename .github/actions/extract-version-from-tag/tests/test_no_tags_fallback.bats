#!/usr/bin/env bats
# Test fallback in a git repo with no tags

GIT_ROOT="$(git rev-parse --show-toplevel)"
HELPERS_DIR="$GIT_ROOT/.github/actions/extract-version-from-tag/tests/helpers"
load "$HELPERS_DIR/setup.bash"

setup() {
    reset_inputs
    setup_test_dir

    # Create a minimal git repo with no tags
    BARE_REPO="$TEST_TMPDIR/bare-repo"
    mkdir -p "$BARE_REPO"
    cd "$BARE_REPO"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    git commit --allow-empty -m "initial" -q

    VERSION_FILE="nonexistent"
    GITHUB_REF=""
}

teardown() {
    teardown_test_dir
}

@test "no-tags repo produces 0.0.0-dev+sha fallback" {
    cd "$BARE_REPO"

    resolve_version
    [ "$SOURCE" = "fallback" ]
    [[ "$VERSION" =~ ^0\.0\.0-dev\+ ]]
    [[ "$GIT_TAG" =~ ^0\.0\.0-dev\+ ]]
}

@test "no-tags fallback sha matches HEAD" {
    cd "$BARE_REPO"
    local expected_sha
    expected_sha=$(git rev-parse --short HEAD)

    resolve_version
    [ "$VERSION" = "0.0.0-dev+${expected_sha}" ]
}
