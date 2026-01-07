#!/usr/bin/env bats

GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_ARTIFACTS_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts"
HELPERS_DIR="$DEPLOY_ARTIFACTS_DIR/tests/helpers"

# Load helper files
load "$HELPERS_DIR/setup.bash"
load "$HELPERS_DIR/command_parsers.bash"
load "$HELPERS_DIR/assertions.bash"

setup_file() {
  setup_test_artifacts
  
  # Verify expected file fixtures exist (JAR as Maven artifact, ZIP and TAR.GZ as generic)
  local -a expected_files=(
    "$BUILD_ARTIFACTS_DIR/test.jar"
    "$BUILD_ARTIFACTS_DIR/test.zip"
    "$BUILD_ARTIFACTS_DIR/test.tar.gz"
  )
  
  local missing=0
  
  for file in "${expected_files[@]}"; do
    if [[ ! -f "$file" ]]; then
      echo "Error: Missing expected fixture: $file" >&2
      missing=1
    fi
  done
  
  if [[ $missing -eq 1 ]]; then
    echo "Test fixtures are incomplete. Please check create-test-fixtures.sh" >&2
    return 1
  fi
}

teardown_file() {
  teardown_test_artifacts
}

@test "All file types are uploaded correctly" {
  # Run entrypoint with dry-run
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")
  
  local upload_commands
  upload_commands=$(extract_upload_commands "$output")
  
  local build_commands
  build_commands=$(extract_build_commands "$output")
  
  # Verify command counts (includes 2 NuGet packages: root + subdirectory)
  assert_command_count "$upload_commands" 10
  assert_command_count "$build_commands" 3
  
  # Parse commands into arrays
  mapfile -t upload_cmd_array < <(echo "$upload_commands")
  
  # Validate file uploads (JAR as Maven, ZIP and TAR.GZ as generic)
  local jar_found=false
  local zip_found=false
  local tar_found=false
  
  for cmd in "${upload_cmd_array[@]}"; do
    # Check for JAR file (should be uploaded as Maven artifact)
    if [[ $cmd =~ test\.jar ]]; then
      jar_found=true
      assert_upload_command_valid "$cmd" "test.jar" "test-project-maven-dev-local" \
        "group_id=com.example.test;package_name=test;version=test" \
        "test-build" "12345-artifacts" "test-project"
    fi
    
    # Check for ZIP file
    if [[ $cmd =~ test\.zip ]]; then
      zip_found=true
      assert_upload_command_valid "$cmd" "test.zip" "test-project-generic-dev-local" "" \
        "test-build" "12345-artifacts" "test-project"
    fi
    
    # Check for TAR.GZ file
    if [[ $cmd =~ test\.tar\.gz ]]; then
      tar_found=true
      assert_upload_command_valid "$cmd" "test.tar.gz" "test-project-generic-dev-local" "" \
        "test-build" "12345-artifacts" "test-project"
    fi
  done
  
  # Verify files were found
  [[ $jar_found == true ]] || (echo "JAR file upload not found" >&2 && return 1)
  [[ $zip_found == true ]] || (echo "ZIP file upload not found" >&2 && return 1)
  [[ $tar_found == true ]] || (echo "TAR.GZ file upload not found" >&2 && return 1)

  # NuGet packages should ONLY go to nuget-dev-local, never generic-dev-local
  # nuget has special handling so gets extra verification.
  local nupkg_in_generic_found=false
  for cmd in "${upload_cmd_array[@]}"; do
    if [[ $cmd =~ \.nupkg ]] && [[ $cmd =~ test-project-generic-dev-local ]]; then
      echo "FAIL: NuGet package found in generic repository upload: $cmd" >&2
      nupkg_in_generic_found=true
    fi
  done
  [[ $nupkg_in_generic_found == false ]] || (echo "NuGet packages were incorrectly uploaded to generic repository" >&2 && return 1)
  
  # Validate build-publish command
  local found_publish=false
  mapfile -t build_cmd_array < <(echo "$build_commands")
  for cmd in "${build_cmd_array[@]}"; do
    if [[ $cmd =~ build-publish ]]; then
      assert_build_command_valid "$cmd" "test-build" "12345-artifacts" "test-project"
      found_publish=true
      break
    fi
  done
  
  [[ $found_publish == true ]] || (echo "build-publish command not found" >&2 && return 1)
}

