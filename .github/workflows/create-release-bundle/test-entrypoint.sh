#!/usr/bin/env bash
# Test suite for create-release-bundle workflow
set -euo pipefail
export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Find the git root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_ROOT="$(git rev-parse --show-toplevel)"

# Define test directory
TEST_DIR="$GIT_ROOT/.github/workflows/create-release-bundle/test-artifacts"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
TEST_REPORT_FILE="$TEST_DIR/test-report.txt"
trap 'handle_error ${LINENO}' ERR

# shellcheck disable=SC2317
handle_error() {
    local exit_code=$?
    local line_number=$1
    echo "Error: Command failed with exit code $exit_code at line $line_number" >&2
    exit 1
}

# Function to record test results
record_test_result() {
    local test_name="$1"
    local success="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ $success == "true" ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo "✅ $test_name - PASSED" >>"$TEST_REPORT_FILE"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo "❌ $test_name - FAILED" >>"$TEST_REPORT_FILE"
    fi
}

# shellcheck disable=SC2317
cleanup() {
    rm -rf "$TEST_DIR"
}

# Set trap to cleanup on exit (success or error)
trap cleanup EXIT

echo "Git root: $GIT_ROOT"
echo "Script dir: $SCRIPT_DIR"

# Change to git root for consistent context
cd "$GIT_ROOT" || exit 1

# Test 1: Basic successful release bundle creation
echo ""
echo "Test 1: Basic successful release bundle creation"
test1_success=true

cd "$TEST_DIR"
output=$("$SCRIPT_DIR/entrypoint.sh" --project test-project --build-names "test-build-1:1728052628123,test-build-2:1728052628123" --bundle-name test-bundle --version v1.0.0 --dry-run 2>&1)

if ! echo "$output" | grep -q "Would execute create-release-bundle workflow"; then
    test1_success=false
fi

if ! echo "$output" | grep -q "Project: test-project"; then
    test1_success=false
fi

if ! echo "$output" | grep -q "Bundle name: test-bundle"; then
    test1_success=false
fi

if ! echo "$output" | grep -q "Version: v1.0.0"; then
    test1_success=false
fi

record_test_result "Test 1: Basic successful release bundle creation" "$test1_success"

# Test 2: Dry-run mode with single build
echo ""
echo "Test 2: Dry-run mode with single build"
test2_success=true

cd "$TEST_DIR"
output=$("$SCRIPT_DIR/entrypoint.sh" --project single-project --build-names "single-build:1728052628123" --bundle-name single-bundle --version v2.0.2 --dry-run 2>&1)

if ! echo "$output" | grep -q "Would execute create-release-bundle workflow"; then
    test2_success=false
fi

if ! echo "$output" | grep -q "Build names: single-build:1728052628123"; then
    test2_success=false
fi

record_test_result "Test 2: Dry-run mode with single build" "$test2_success"

# Test 3: Error handling - missing required parameters
echo ""
echo "Test 3: Error handling - missing required parameters"
test3_success=true

cd "$TEST_DIR"

# Test missing project
if "$SCRIPT_DIR/entrypoint.sh" --build-names "test-build" --bundle-name test-bundle --version v1.0.0 2>/dev/null; then
    test3_success=false
fi

# Test missing build names
if "$SCRIPT_DIR/entrypoint.sh" --project test-project --bundle-name test-bundle --version v1.0.0 2>/dev/null; then
    test3_success=false
fi

# Test missing bundle name
if "$SCRIPT_DIR/entrypoint.sh" --project test-project --build-names "test-build:1728052628123" --version v1.0.0 2>/dev/null; then
    test3_success=false
fi

# Test missing version
if "$SCRIPT_DIR/entrypoint.sh" --project test-project --build-names "test-build:1728052628123" --bundle-name test-bundle 2>/dev/null; then
    test3_success=false
fi

record_test_result "Test 3: Error handling - missing required parameters" "$test3_success"

# Test 4: Error handling - invalid build name format (missing version)
echo ""
echo "Test 4: Error handling - invalid build name format (missing version)"
test4_success=true

cd "$TEST_DIR"

# Test build name without version
if "$SCRIPT_DIR/entrypoint.sh" --project test-project --build-names "test-build" --bundle-name test-bundle --version v1.0.0 2>/dev/null; then
    test4_success=false
fi

# Test build name with invalid format
if "$SCRIPT_DIR/entrypoint.sh" --project test-project --build-names "test-build-v1.0.0" --bundle-name test-bundle --version v1.0.0 2>/dev/null; then
    test4_success=false
fi

record_test_result "Test 4: Error handling - invalid build name format (missing version)" "$test4_success"

# Test 5: Bundle metadata path triggers release-bundle-annotate in dry-run
echo ""
echo "Test 5: Bundle metadata dotfile path triggers annotate (dry-run)"
test5_success=true

cd "$TEST_DIR"
cat >"$TEST_DIR/.maven-bundle-metadata.json" <<'JSON'
{"is_multi_package":true,"maven_module_count":2,"maven_aggregator_present":true,"is_flattened":false}
JSON
output=$("$SCRIPT_DIR/entrypoint.sh" --project test-project --build-names "test-build:1728052628123" --bundle-name meta-bundle --version v3.0.0 --bundle-metadata "$TEST_DIR/.maven-bundle-metadata.json" --dry-run 2>&1)

if ! echo "$output" | grep -q "jf release-bundle-annotate"; then
    test5_success=false
fi
if ! echo "$output" | grep -q "is_multi_package=true"; then
    test5_success=false
fi
if ! echo "$output" | grep -q "maven_module_count=2"; then
    test5_success=false
fi

record_test_result "Test 5: Bundle metadata dotfile path triggers annotate (dry-run)" "$test5_success"

# Test 6: Revision forms the bundle version without changing the release version
echo ""
echo "Test 6: Revision appends to the bundle version (dry-run)"
test6_success=true

cd "$TEST_DIR"
output=$("$SCRIPT_DIR/entrypoint.sh" --project test-project --build-names "test-build:1728052628123" --bundle-name rev-bundle --version v1.2.3 --revision 4711-2 --dry-run 2>&1)

if ! echo "$output" | grep -q "jf release-bundle-create rev-bundle v1.2.3-4711-2"; then
    test6_success=false
fi
if ! echo "$output" | grep -q "Bundle version: v1.2.3-4711-2 (revision 4711-2)"; then
    test6_success=false
fi
if ! echo "$output" | grep -q '"description": "Release for build version v1.2.3"'; then
    test6_success=false
fi
if ! echo "$output" | grep -q '"version": "v1.2.3-4711-2"'; then
    test6_success=false
fi

record_test_result "Test 6: Revision appends to the bundle version (dry-run)" "$test6_success"

# Test 7: Without a revision the bundle version is the release version
echo ""
echo "Test 7: No revision leaves the bundle version unchanged (dry-run)"
test7_success=true

cd "$TEST_DIR"
output=$("$SCRIPT_DIR/entrypoint.sh" --project test-project --build-names "test-build:1728052628123" --bundle-name norev-bundle --version v1.2.3 --dry-run 2>&1)

if ! echo "$output" | grep -q "jf release-bundle-create norev-bundle v1.2.3"; then
    test7_success=false
fi
if echo "$output" | grep -q "Bundle version:"; then
    test7_success=false
fi

record_test_result "Test 7: No revision leaves the bundle version unchanged (dry-run)" "$test7_success"

# Test 8: The resolved bundle version is exposed as a step output
echo ""
echo "Test 8: Bundle version is written to GITHUB_OUTPUT"
test8_success=true

cd "$TEST_DIR"
: >"$TEST_DIR/gh-output"
GITHUB_OUTPUT="$TEST_DIR/gh-output" "$SCRIPT_DIR/entrypoint.sh" --project test-project --build-names "test-build:1728052628123" --bundle-name out-bundle --version v9.9.9 --revision 1-1 --dry-run >/dev/null 2>&1

if ! grep -q "^bundle-version=v9.9.9-1-1$" "$TEST_DIR/gh-output"; then
    test8_success=false
fi

record_test_result "Test 8: Bundle version is written to GITHUB_OUTPUT" "$test8_success"

# Summary
echo ""
echo "Test report: $TEST_REPORT_FILE"
cat "$TEST_REPORT_FILE"

if [[ $FAILED_TESTS -eq 0 ]]; then
    echo ""
    echo "🎉 All tests passed successfully!"
    echo "✅ Test suite completed with exit code 0"
    exit 0
else
    echo ""
    echo "❌ Test suite completed with exit code 1"
    exit 1
fi
