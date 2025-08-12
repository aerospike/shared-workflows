#!/usr/bin/env bash
# Test suite for build-artifacts workflow
set -euo pipefail
export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'

TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Find the git root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_ROOT="$(git rev-parse --show-toplevel)"

# Define test directory
TEST_DIR="$GIT_ROOT/.github/workflows/execute-build/test-artifacts"
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


cp -r "$GIT_ROOT/.github/workflows/execute-build/test_apps" "$TEST_DIR"

# Function to record test results
record_test_result() {
    local test_name="$1"
    local success="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ "$success" == "true" ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo "✅ $test_name - PASSED" >> "$TEST_REPORT_FILE"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo "❌ $test_name - FAILED" >> "$TEST_REPORT_FILE"
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

# Create test directory

# Create test build scripts
cat > "$TEST_DIR/simple-build.sh" << 'EOF'
#!/bin/bash
# Simple test build script
echo "Starting build..."
mkdir -p build-output
echo "Built artifact 1" > build-output/artifact1.txt
echo "Built artifact 2" > build-output/artifact2.txt
echo "Build completed successfully"
EOF

cat > "$TEST_DIR/failing-build.sh" << 'EOF'
#!/bin/bash
# Build script that fails
echo "Starting build..."
echo "Build failed!" >&2
exit 1
EOF

cat > "$TEST_DIR/no-artifacts-build.sh" << 'EOF'
#!/bin/bash
# Build script that doesn't create artifacts
echo "Starting build..."
echo "Build completed but no artifacts created"
EOF

chmod +x "$TEST_DIR"/*.sh

# Test 1: Basic successful build
echo ""
echo " Test 1: Basic successful build"
test1_success=true

cd "$TEST_DIR"
if ! "$SCRIPT_DIR/entrypoint.sh" --build-script-path simple-build.sh --artifact-directory build-output; then
    test1_success=false
fi

if [[ ! -f "build-output/artifact1.txt" ]] || [[ ! -f "build-output/artifact2.txt" ]]; then
    test1_success=false
fi

record_test_result "Test 1: Basic successful build" "$test1_success"

# Test 2: Dry-run mode
echo ""
echo " Test 2: Dry-run mode"
test2_success=true

cd "$TEST_DIR"
rm -rf build-output-dry
output=$("$SCRIPT_DIR/entrypoint.sh" --build-script-path simple-build.sh --artifact-directory build-output-dry --dry-run 2>&1)


if ! echo "$output" | grep -q "Would execute: .*simple-build.sh"; then
    test2_success=false
fi

# In dry-run, no actual artifacts should be created
if [[ -d "build-output-dry" ]]; then
    test2_success=false
fi

record_test_result "Test 2: Dry-run mode" "$test2_success"

# Test 3: Error handling - missing build script
echo ""
echo " Test 3: Error handling - missing build script"
test3_success=true

cd "$TEST_DIR"
if "$SCRIPT_DIR/entrypoint.sh" --build-script-path nonexistent-script.sh --artifact-directory build-output 2>/dev/null; then
    test3_success=false
fi

record_test_result "Test 3: Error handling - missing build script" "$test3_success"

# Test 4: Error handling - missing arguments
echo ""
echo " Test 4: Error handling - missing arguments"
test4_success=true

cd "$TEST_DIR"
# Test missing build script argument
if "$SCRIPT_DIR/entrypoint.sh" --artifact-directory build-output 2>/dev/null; then
    test4_success=false
fi

# Test missing artifact directory argument
if "$SCRIPT_DIR/entrypoint.sh" --build-script-path simple-build.sh 2>/dev/null; then
    test4_success=false
fi

record_test_result "Test 4: Error handling - missing arguments" "$test4_success"

# Test 5: Real build using test app
echo ""
echo " Test 5: Real build using test app"
test5_success=true

cd "$TEST_DIR/test_apps/hi"
rm -rf build
if ! "$SCRIPT_DIR/entrypoint.sh" --build-script "make clean && make all" --artifact-directory build; then
    test5_success=false
fi

# Check if the hi executable was built
if [[ ! -f "build/hi" ]]; then
    test5_success=false
fi

# Test that the program works
if [[ "$test5_success" == "true" ]]; then
    output=$(build/hi 2>&1)
    if [[ "$output" != "Hello, world!" ]]; then
        test5_success=false
    fi
fi

record_test_result "Test 5: Real build using test app" "$test5_success"

# Test 6: Script permissions handling
echo ""
echo " Test 6: Script permissions handling"
test6_success=true

cd "$TEST_DIR"
# Create a non-executable script
cat > non-executable.sh << 'EOF'
#!/bin/bash
echo "This script was made executable automatically"
mkdir -p perm-test-output
echo "Test artifact" > perm-test-output/test.txt
EOF

# Don't make it executable
chmod -x non-executable.sh

if ! "$SCRIPT_DIR/entrypoint.sh" --build-script-path non-executable.sh --artifact-directory perm-test-output; then
    test6_success=false
fi

if [[ ! -f "perm-test-output/test.txt" ]]; then
    test6_success=false
fi

record_test_result "Test 6: Script permissions handling" "$test6_success"

# Test 7: No artifacts created error
echo ""
echo "Test 7: Error handling - no artifacts created"
test7_success=true

cd "$TEST_DIR"
if "$SCRIPT_DIR/entrypoint.sh" --build-script-path no-artifacts-build.sh --artifact-directory empty-output 2>/dev/null; then
    test7_success=false
fi

record_test_result "Test 7: Error handling - no artifacts created" "$test7_success"

# Summary

echo "Test report: $TEST_REPORT_FILE"
cat "$TEST_REPORT_FILE"

if [[ $FAILED_TESTS -eq 0 ]]; then
    echo ""
    echo "🎉 All tests passed successfully!"
    echo "✅ Test suite completed with exit code 0"
    exit 0
else
    echo "❌ Test suite completed with exit code 1"
    exit 1
fi 
