#!/usr/bin/env bash
# Setup helpers for extract-version-from-tag bats tests

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/extract-version-from-tag"
ENTRYPOINT="$ACTION_DIR/entrypoint.sh"

# Source the entrypoint so resolve_version() is available
# shellcheck disable=SC1090,SC1091
source "$ENTRYPOINT"

# Create a temp dir for test fixtures
setup_test_dir() {
        TEST_TMPDIR="$(mktemp -d)"
        export TEST_TMPDIR
}

teardown_test_dir() {
        if [[ -n ${TEST_TMPDIR-} && -d $TEST_TMPDIR ]]; then
                rm -rf "$TEST_TMPDIR"
        fi
}

# Reset all variables to clean defaults (used by bats tests via resolve_version)
# shellcheck disable=SC2034
reset_inputs() {
        VERSION_INPUT=""
        TAG_PREFIX="v"
        VERSION_FILE="VERSION"
        GITHUB_REF=""
        OUTPUT_FILE=""
        VERSION=""
        GIT_TAG=""
        SOURCE=""
}
