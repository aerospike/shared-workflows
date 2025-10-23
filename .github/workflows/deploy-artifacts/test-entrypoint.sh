#!/usr/bin/env bash
# set -euo pipefail  # Removed to allow tests to continue even if some verifications fail
export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
trap 'handle_error ${LINENO}' ERR

# Test result tracking
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0
# Find the git root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_ROOT="$(git rev-parse --show-toplevel)"

# Define test directory
TEST_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts/test-artifacts"
BUILD_ARTIFACTS_DIR="$TEST_DIR/build-artifacts"
TEST_REPORT_FILE="$TEST_DIR/test-report.txt"

handle_error() {
    local exit_code=$?
    local line_number=$1
    echo "Error: Command failed with exit code $exit_code at line $line_number" >&2
    exit 1
}

record_test_result() {
    local test_name="$1"
    local success="$2"
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
    if [[ "$success" == "true" ]]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        echo "✅ $test_name - PASSED" >> "$TEST_REPORT_FILE"
    elif [[ "$success" == "skipped" ]]; then
        SKIPPED_TESTS=$((SKIPPED_TESTS + 1))
        echo "⏭️ $test_name - SKIPPED" >> "$TEST_REPORT_FILE"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        echo "❌ $test_name - FAILED" >> "$TEST_REPORT_FILE"
    fi
}


# Cleanup function
cleanup() {


    echo "cleaning up"
#    rm -rf "$TEST_DIR"
}

# Set trap to cleanup on exit (success or error)
trap cleanup EXIT

# Change to git root for consistent context
cd "$GIT_ROOT" || error "Failed to cd to git root $GIT_ROOT"

# Create test directory and fixtures
"$SCRIPT_DIR/create-test-fixtures.sh"

# Define expected test files explicitly
declare -a TEST_FILES=(
    "$BUILD_ARTIFACTS_DIR/test-ubuntu22.04.deb"
    "$BUILD_ARTIFACTS_DIR/test-1.0-2.noarch.rpm"
    "$BUILD_ARTIFACTS_DIR/test.jar"
    "$BUILD_ARTIFACTS_DIR/test.zip"
    "$BUILD_ARTIFACTS_DIR/test.tar.gz"
    "$BUILD_ARTIFACTS_DIR/nested/dir/test-debian12.deb"
    "$BUILD_ARTIFACTS_DIR/nested/dir/nested.rpm"
)

# Function to verify all expected files exist
verify_test_files() {
    local missing_files=()
    for file in "${TEST_FILES[@]}"; do
        if [[ ! -f "$file" ]]; then
            missing_files+=("$file")
        fi
    done
    if [[ ${#missing_files[@]} -gt 0 ]]; then
        echo "❌ Missing expected test files:"
        printf '  %s\n' "${missing_files[@]}"
        exit 1
    fi
    echo " All expected test files present"
}

# Mock functions for testing
# Removed mock_jf - using --dry-run flag instead

# Function to capture and analyze dry-run output
capture_dry_run_output() {
    local test_name="$1"
    local test_args="$2"
    local output_file="$3"
    
    echo "  Running: $test_name"
    echo "   Command: $test_args"
    
    # Run the dry-run and capture output (both stdout and stderr)
    local dry_run_output
    dry_run_output=$(eval "$test_args" 2>&1)
    exit_code=$?
    if [[ $exit_code -ne 0 ]]; then
        #if error print output and move on
        echo "    Error received during dry run"
        echo "$dry_run_output"
    fi
    
    echo "Save the full output to $output_file"
    echo "$dry_run_output" > "$output_file"
    # Extract and save specific command types
    echo "$dry_run_output" | grep -E "jf rt upload" > "${output_file}.upload_commands" || true
    echo "$dry_run_output" | grep -E "jf rt build-" > "${output_file}.build_commands" || true
    echo "$dry_run_output" | grep -E "Processing (DEB|RPM):" > "${output_file}.processing_lines" || true
    echo "$dry_run_output" | grep -E "Uploading (signature|checksum):" > "${output_file}.signature_lines" || true
    echo "$dry_run_output" | grep -E "Would upload.*packages to JFrog" > "${output_file}.upload_sections" || true
    echo "$dry_run_output" | grep -E "Would publish.*build info" > "${output_file}.build_sections" || true
    
    echo "   Output saved to: $output_file"

}

# Function to verify command patterns
verify_commands() {
    local test_name="$1"
    local commands_file="$2"
    local expected_patterns="$3"
    local test_count=0
    local passed_count=0
    
    echo "   Verifying commands for: $test_name"
    
    if [[ ! -f "$commands_file" ]]; then
        echo "    ❌ Commands file not found: $commands_file"
        return 1
    fi
    
    while IFS= read -r pattern; do
        if [[ -n "$pattern" ]]; then
            test_count=$((test_count + 1))
            if grep -q "$pattern" "$commands_file"; then
                echo "     Pattern found: $pattern"
                passed_count=$((passed_count + 1))
            else
                echo "     Pattern not found: $pattern"
            fi
        fi
    done <<< "$expected_patterns"
    
    echo "     Command verification: $passed_count/$test_count patterns matched"
    if [[ $passed_count -eq $test_count ]]; then
        return 0
    else
        return 1
    fi
}

# Function to verify command counts
verify_command_count() {
    local test_name="$1"
    local commands_file="$2"
    local expected_count="$3"
    
    echo "   Verifying command count for: $test_name"
    
    if [[ ! -f "$commands_file" ]]; then
        echo "    ❌ Commands file not found: $commands_file"
        return 1
    fi
    
    local actual_count
    actual_count=$(wc -l < "$commands_file")
    
    if [[ "$actual_count" -eq "$expected_count" ]]; then
        echo "     Command count matches: expected $expected_count, actual $actual_count"
        return 0
    else
        echo "    ❌ Command count mismatch: expected $expected_count, actual $actual_count"
        return 1
    fi
}

# Test 1: Test with specific file types (DEB and RPM)
echo ""
echo " Test 1: Uploading specific file types (DEB and RPM)"
cd "$TEST_DIR" || error "Failed to cd to $TEST_DIR"

# Set up environment for the test - only mock jf command
# Removed mock_jf - using --dry-run flag instead

capture_dry_run_output \
    "DEB and RPM upload test" \
    "$SCRIPT_DIR/entrypoint.sh test-project test-build v1.0.0 12345 12345-metadata --dry-run" \
    "$TEST_DIR/test1_output.txt"

echo ""
echo " Results for Test 1:"
test1_success=true

if ! verify_commands "DEB upload commands" "$TEST_DIR/test1_output.txt.upload_commands" "
jf rt upload.*test-ubuntu22.04.deb.*test-project-deb-dev-local
jf rt upload.*test-debian12.deb.*test-project-deb-dev-local
jf rt upload.*test-1.0-2.noarch.rpm.*test-project-rpm-dev-local
jf rt upload.*nested.rpm.*test-project-rpm-dev-local
target-props.*deb.distribution=jammy
target-props.*deb.distribution=bookworm
target-props.*rpm.distribution=
"; then
    test1_success=false
    cat "$TEST_DIR/test1_output.txt.upload_commands"
fi

if ! verify_commands "Build info commands" "$TEST_DIR/test1_output.txt.build_commands" "
jf rt build-publish.*test-build.*12345
"; then
    test1_success=false
    cat "$TEST_DIR/test1_output.txt.build_commands"
fi

if ! verify_command_count "Upload commands" "$TEST_DIR/test1_output.txt.upload_commands" 8; then
    test1_success=false
    echo "Wrong number of commands"
    cat "$TEST_DIR/test1_output.txt.upload_commands"
fi

if ! verify_command_count "Build commands" "$TEST_DIR/test1_output.txt.build_commands" 3; then
    test1_success=false
    echo "Wrong number of commands"
    cat "$TEST_DIR/test1_output.txt.build_commands"
fi

record_test_result "Test 1: artifacts upload" "$test1_success"
record_test_result "Test 2:" "skipped"

# Test 3: Test with all files
echo ""
echo " Test 3: Uploading all files"
capture_dry_run_output \
    "All files upload test" \
    "$SCRIPT_DIR/entrypoint.sh test-project test-build v1.0.0 12345 12345-metadata --dry-run" \
    "$TEST_DIR/test3_output.txt"

echo ""
echo " Results for Test 3:"
test3_success=true


if ! verify_commands "All build info commands" "$TEST_DIR/test3_output.txt.build_commands" "
jf rt build-publish.*test-build.*12345
"; then
    test3_success=false
fi

if ! verify_command_count "All upload commands" "$TEST_DIR/test3_output.txt.upload_commands" 8; then
    test3_success=false
fi

if ! verify_command_count "All build commands" "$TEST_DIR/test3_output.txt.build_commands" 3; then
    test3_success=false
fi

record_test_result "Test 3: All files upload" "$test3_success"

# Test 4: Test error handling
echo ""
echo " Test 4: Error handling"
test4_success=true

echo "  Testing missing project argument..."
# trunk-ignore(shellcheck/SC2015)
missing_project_output=$(cd "$TEST_DIR" && "$SCRIPT_DIR/entrypoint.sh" 2>&1 || true)
if echo "$missing_project_output" | grep -q "Error: project is required"; then
    echo "     Missing project error handled correctly"
else
    echo "     Missing project error not handled correctly"
    echo "$missing_project_output"
    test4_success=false
fi

echo "  Testing missing build-name argument..."
# shellcheck disable=SC2015
missing_build_name_output=$(cd "$TEST_DIR" && "$SCRIPT_DIR/entrypoint.sh" test-project 2>&1 || true)
if echo "$missing_build_name_output" | grep -q "Error: build-name is required"; then
    echo "     Missing build-name error handled correctly"
else
    echo "     Missing build-name error not handled correctly"
    echo "$missing_build_name_output"
    test4_success=false
fi

echo "  Testing missing version argument..."
# shellcheck disable=SC2015
missing_version_output=$(cd "$TEST_DIR" && "$SCRIPT_DIR/entrypoint.sh" test-project test-build 2>&1 || true)
if echo "$missing_version_output" | grep -q "Error: version is required"; then
    echo "     Missing version error handled correctly"
else
    echo "     Missing version error not handled correctly"
    echo "$missing_version_output"
    test4_success=false
fi

echo "  Testing missing build-number argument..."
# shellcheck disable=SC2015

missing_build_number_output=$(cd "$TEST_DIR" && "$SCRIPT_DIR/entrypoint.sh" test-project test-build v1.0.0 2>&1 || true)
if echo "$missing_build_number_output" | grep -q "Error: build-number is required"; then
    echo "     Missing build-number error handled correctly"
else
    echo "     Missing build-number error not handled correctly"
    echo "$missing_build_number_output"
    test4_success=false
fi

echo "  Testing invalid option..."
# shellcheck disable=SC2015
invalid_option_output=$(cd "$TEST_DIR" && "$SCRIPT_DIR/entrypoint.sh" --invalid-option test-project test-build v1.0.0 12345 12345-metadata 2>&1 || true)
if echo "$invalid_option_output" | grep -q "Unknown option"; then
    echo "     Invalid option error handled correctly"
else
    echo "     Invalid option error not handled correctly"
    echo "$invalid_option_output"
    test4_success=false
fi

record_test_result "Test 4: Error handling" "$test4_success"

# Test 5: Test structured build artifacts
echo ""
echo " Test 5: Structured build artifacts"
test5_success=true

echo "  Testing structured build artifacts creation..."
# shellcheck disable=SC2015
structured_output=$(cd "$TEST_DIR" &&  "$SCRIPT_DIR/entrypoint.sh" test-project test-build v1.0.0 12345 12345-metadata --dry-run 2>&1 || true)
if echo "$structured_output" | grep -q "Processing DEB:"; then
    echo "     Structured build artifacts processing works correctly"
else
    echo "    Structured build artifacts processing not working correctly"
    echo "$structured_output"
    test5_success=false
fi

echo "  Testing RPM processing..."
# shellcheck disable=SC2015
if echo "$structured_output" | grep -q "Processing RPM:"; then
    echo "     RPM processing works correctly"
else
    echo "     RPM processing not working correctly"
    echo "$structured_output"
    test5_success=false
fi

record_test_result "Test 5: Structured build artifacts" "$test5_success"

# Summary

cat "$TEST_REPORT_FILE"

if [[ $FAILED_TESTS -eq 0 ]]; then
    echo ""
    echo "🎉 All tests passed successfully!"
else
    echo ""
    echo "❌ Test failures."
    exit 1
fi
