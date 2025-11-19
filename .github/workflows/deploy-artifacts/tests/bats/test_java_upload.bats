#!/usr/bin/env bats
# Test Java artifact upload with validation

# Get absolute paths - use git root to find helpers
GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_ARTIFACTS_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts"
HELPERS_DIR="$DEPLOY_ARTIFACTS_DIR/tests/helpers"

# Load helper files
load "$HELPERS_DIR/setup.bash"
load "$HELPERS_DIR/command_parsers.bash"
load "$HELPERS_DIR/assertions.bash"

setup_file() {
  setup_test_artifacts
  
  # Verify expected Java artifact fixtures exist
  local -a expected_jars=(
    "$BUILD_ARTIFACTS_DIR/test.jar"
  )
  
  local missing=0
  
  for jar in "${expected_jars[@]}"; do
    if [[ ! -f "$jar" ]]; then
      echo "Error: Missing expected JAR fixture: $jar" >&2
      missing=1
    fi
  done
  
  if [[ $missing -eq 1 ]]; then
    echo "Test fixtures are incomplete. Please check create-test-fixtures.sh" >&2
    return 1
  fi
  
  # Verify we have the expected count
  local actual_jar_count
  actual_jar_count=$(find "$BUILD_ARTIFACTS_DIR" -name "*.jar" -type f | wc -l)
  
  if [[ $actual_jar_count -ne ${#expected_jars[@]} ]]; then
    echo "Warning: Expected ${#expected_jars[@]} JAR files but found $actual_jar_count" >&2
  fi
}

teardown_file() {
  teardown_test_artifacts
}

@test "Java artifacts are uploaded correctly" {
  # Run entrypoint with dry-run
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")
  
  # Extract upload commands
  local upload_commands
  upload_commands=$(extract_upload_commands "$output")
  
  # Parse commands into array
  mapfile -t upload_cmd_array < <(echo "$upload_commands")
  
  # Find Java artifact upload commands
  local jar_found=false
  for cmd in "${upload_cmd_array[@]}"; do
    if [[ $cmd =~ \.jar ]]; then
      jar_found=true
      
      # Java artifacts go to generic repo
      local expected_repo="test-project-generic-dev-local"
      
      # Extract filename from command
      local filename
      if [[ $cmd =~ ([^/]+\.jar) ]]; then
        filename="${BASH_REMATCH[1]}"
      fi
      
      # Validate command structure
      assert_upload_command_valid "$cmd" "$filename" "$expected_repo" "" \
        "test-build" "12345-artifacts" "test-project"
    fi
  done
  
  # Verify Java artifacts were found and processed
  [[ $jar_found == true ]] || (echo "Java artifact upload not found" >&2 && return 1)
}

@test "Java artifacts preserve directory structure" {
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")
  
  # Extract upload commands
  local upload_commands
  upload_commands=$(extract_upload_commands "$output")
  
  # Check that --flat=false is present for Java uploads
  local jar_commands
  jar_commands=$(echo "$upload_commands" | grep -E "\.jar" || true)
  
  if [[ -n "$jar_commands" ]]; then
    while IFS= read -r cmd; do
      [[ $cmd == *"--flat=false"* ]] || (echo "Java upload missing --flat=false: $cmd" >&2 && return 1)
    done <<< "$jar_commands"
  fi
}

@test "Java artifacts are not skipped" {
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")
  
  # Verify "Processing generic file:" messages appear for JAR files
  [[ $output == *"Processing generic file:"* ]] || (echo "Generic file processing messages not found" >&2 && return 1)
  
  # Extract upload commands and verify JAR is present
  local upload_commands
  upload_commands=$(extract_upload_commands "$output")
  
  [[ $upload_commands == *".jar"* ]] || (echo "JAR file upload command not found" >&2 && return 1)
}

