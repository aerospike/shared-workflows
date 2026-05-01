#!/usr/bin/env bats
# Test structured build artifacts processing messages

# Get absolute paths - use git root to find helpers
GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_ARTIFACTS_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts"
HELPERS_DIR="$DEPLOY_ARTIFACTS_DIR/tests/helpers"

# Load helper files
load "$HELPERS_DIR/setup.bash"
load "$HELPERS_DIR/assertions.bash"

setup_file() {
  setup_test_artifacts
}

teardown_file() {
  teardown_test_artifacts
}

@test "DEB processing messages appear" {
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")
  
  assert_processing_message "$output" "DEB"
}

@test "RPM processing messages appear" {
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")
  
  assert_processing_message "$output" "RPM"
}

@test "WIN processing messages appear" {
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

  assert_processing_message "$output" "WIN"
}

@test "Deploy dry-run logs Windows upload for win type (generic-dev-local)" {
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

  [[ "$output" == *"Uploading Windows artifacts"* ]]
  [[ "$output" == *"Uploading Windows file:"*"ci-win-fixture.exe"* ]]
  [[ "$output" == *"Uploading Windows file:"*"ci-win-fixture.msi"* ]]
  [[ "$output" == *"Uploading Windows file:"*"ci-win-fixture.msix"* ]]
}

@test "Structured artifact directories are created" {
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")
  
  # Verify structured directories exist
  # this list will grow as we have more types such as nupkg, etc.
  [[ -d "$TEST_DIR/structured_build_artifacts/deb" ]]
  [[ -d "$TEST_DIR/structured_build_artifacts/rpm" ]]
  [[ -d "$TEST_DIR/structured_build_artifacts/win" ]]
  [[ -d "$TEST_DIR/structured_build_artifacts/generic" ]]
}

