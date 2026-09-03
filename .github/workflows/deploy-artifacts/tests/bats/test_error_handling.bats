#!/usr/bin/env bats
# Test error handling for missing arguments and invalid options


GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_ARTIFACTS_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts"
HELPERS_DIR="$DEPLOY_ARTIFACTS_DIR/tests/helpers"

# Load helper files
load "$HELPERS_DIR/setup.bash"

setup_file() {
  setup_test_artifacts
}

teardown_file() {
  teardown_test_artifacts
}

@test "Missing project argument produces error" {
  run "$DEPLOY_ARTIFACTS_DIR/entrypoint.sh" 2>&1
  
  [[ $status -ne 0 ]]
  [[ $output == *"Error: project is required"* ]]
}

@test "Missing build-name argument produces error" {
  run "$DEPLOY_ARTIFACTS_DIR/entrypoint.sh" test-project 2>&1
  
  [[ $status -ne 0 ]]
  [[ $output == *"Error: build-name is required"* ]]
}

@test "Missing version argument produces error" {
  run "$DEPLOY_ARTIFACTS_DIR/entrypoint.sh" test-project test-build 2>&1
  
  [[ $status -ne 0 ]]
  [[ $output == *"Error: version is required"* ]]
}

@test "Missing build-number argument produces error" {
  run "$DEPLOY_ARTIFACTS_DIR/entrypoint.sh" test-project test-build v1.0.0 2>&1
  
  [[ $status -ne 0 ]]
  [[ $output == *"Error: build-number is required"* ]]
}

@test "Invalid option produces error" {
  run "$DEPLOY_ARTIFACTS_DIR/entrypoint.sh" --invalid-option test-project test-build v1.0.0 12345 12345-metadata 2>&1
  
  [[ $status -ne 0 ]]
  [[ $output == *"Unknown option"* ]]
}

@test "Help mentions --deb-distributions" {
  run "$DEPLOY_ARTIFACTS_DIR/entrypoint.sh" --help
  [[ $status -eq 0 ]]
  [[ $output == *"--deb-distributions"* ]]
}

