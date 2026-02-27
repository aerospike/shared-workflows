#!/usr/bin/env bash
# Create test fixtures for artifacts-cicd bats tests
# Uses real package files from tests/ directory, renamed to match expected patterns
set -euo pipefail

GIT_ROOT="$(git rev-parse --show-toplevel)"
FIXTURES_DIR="$GIT_ROOT/.github/workflows/artifacts-cicd/tests/test-artifacts"

# Source fixtures
SRC_DEB="$GIT_ROOT/tests/nano-tiny_8.4-1_arm64.deb"
SRC_RPM="$GIT_ROOT/tests/test-1.0-2.noarch.rpm"
SRC_NUPKG="$GIT_ROOT/tests/some/structure/Aerospike.Client.8.0.2.nupkg"

# Skip if fixtures already exist (idempotent)
if [[ -d $FIXTURES_DIR ]]; then
    echo "Fixtures already exist at $FIXTURES_DIR — skipping"
    exit 0
fi

# Verify source fixtures exist
for src in "$SRC_DEB" "$SRC_RPM" "$SRC_NUPKG"; do
    if [[ ! -f $src ]]; then
        echo "ERROR: Source fixture not found: $src" >&2
        exit 1
    fi
done

echo "Creating test fixtures..."

# --- multi-distro: 3 native packages (el9, jammy, noble) ---
MULTI="$FIXTURES_DIR/multi-distro"
mkdir -p "$MULTI"
cp "$SRC_RPM" "$MULTI/hi-1.0.0-test-1.el9.x86_64.rpm"
cp "$SRC_DEB" "$MULTI/hi_1.0.0-test_ubuntu22.04_x86_64.deb"
cp "$SRC_DEB" "$MULTI/hi_1.0.0-test_ubuntu24.04_x86_64.deb"

# --- mixed-matrix: 1 native + 1 nupkg ---
MIXED="$FIXTURES_DIR/mixed-matrix"
mkdir -p "$MIXED"
cp "$SRC_DEB" "$MIXED/hi_1.0.0-test_ubuntu22.04_x86_64.deb"
cp "$SRC_NUPKG" "$MIXED/Aerospike.HelloWorld.1.0.0-test.nupkg"

# Note: signing test fixtures are not generated here — those tests
# validate real pipeline-signed artifacts and only run in CI.

echo "Fixtures created:"
find "$FIXTURES_DIR" -type f | sort
