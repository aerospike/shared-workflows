#!/usr/bin/env bats

# Get absolute paths - use git root to find helpers
GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_ARTIFACTS_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts"
HELPERS_DIR="$DEPLOY_ARTIFACTS_DIR/tests/helpers"

load "$HELPERS_DIR/setup.bash"
load "$HELPERS_DIR/command_parsers.bash"
load "$HELPERS_DIR/assertions.bash"

setup_file() {
  setup_test_artifacts
  
  # Verify expected NuGet package fixtures exist
  local -a expected_nupkgs=(
    "$BUILD_ARTIFACTS_DIR/Aerospike.Client.8.0.2.nupkg"
  )
  
  local missing=0
  
  for nupkg in "${expected_nupkgs[@]}"; do
    if [[ ! -f "$nupkg" ]]; then
      echo "Error: Missing expected NuGet fixture: $nupkg" >&2
      missing=1
    fi
  done
  
  if [[ $missing -eq 1 ]]; then
    echo "Test fixtures are incomplete. Please check create-test-fixtures.sh" >&2
    return 1
  fi
  
  # Verify we have the expected count
  local actual_nupkg_count
  actual_nupkg_count=$(find "$BUILD_ARTIFACTS_DIR" -name "*.nupkg" -type f | wc -l)
  
  if [[ $actual_nupkg_count -ne ${#expected_nupkgs[@]} ]]; then
    echo "Warning: Expected ${#expected_nupkgs[@]} NuGet packages but found $actual_nupkg_count" >&2
  fi
}

teardown_file() {
  teardown_test_artifacts
}

@test "NuGet packages are processed correctly" {
  # Run entrypoint with dry-run
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")
  
  # Verify "Processing NUPKG:" messages appear
  assert_processing_message "$output" "NUPKG"
  
  # Extract upload commands
  local upload_commands
  upload_commands=$(extract_upload_commands "$output")
  
  # Parse commands into array
  mapfile -t upload_cmd_array < <(echo "$upload_commands")
  
  # Find NuGet package upload commands
  local nupkg_found=false
  local nupkg_commands=()
  for cmd in "${upload_cmd_array[@]}"; do
    if [[ $cmd =~ \.nupkg ]]; then
      nupkg_found=true
      
      # NuGet packages go to NuGet-specific repository
      local expected_repo="test-project-nuget-dev-local"
      
      # Extract filename from command
      local filename
      if [[ $cmd =~ ([^/]+\.nupkg) ]]; then
        filename="${BASH_REMATCH[1]}"
      fi
      
      nupkg_commands+=("$cmd")
      # Validate command structure
      assert_upload_command_valid "$cmd" "$filename" "$expected_repo" "" \
        "test-build" "12345-artifacts" "test-project"
    fi
  done

  # Verify we found exactly 1 NuGet package command
  [[ ${#nupkg_commands[@]} -eq 1 ]] || (echo "Expected 1 NuGet command, found ${#nupkg_commands[@]}" >&2 && return 1)

  # Verify NuGet packages were found and processed
  [[ $nupkg_found == true ]] || (echo "NuGet package upload not found" >&2 && return 1)
}

@test "NuGet packages preserve directory structure" {
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")
  
  # Extract upload commands
  local upload_commands
  upload_commands=$(extract_upload_commands "$output")
  
  # Check that --flat=false is present for NuGet uploads
  local nupkg_commands
  nupkg_commands=$(echo "$upload_commands" | grep -E "\.nupkg" || true)
  
  if [[ -n "$nupkg_commands" ]]; then
    while IFS= read -r cmd; do
      [[ $cmd == *"--flat=false"* ]] || (echo "NuGet upload missing --flat=false: $cmd" >&2 && return 1)
    done <<< "$nupkg_commands"
  fi
}

