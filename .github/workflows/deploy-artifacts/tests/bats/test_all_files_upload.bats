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

  # Verify expected file fixtures exist
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

@test "JAR routes to maven and generic files route to generic repo" {
  # Run entrypoint with dry-run
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

  local upload_commands
  upload_commands=$(extract_upload_commands "$output")

  local build_commands
  build_commands=$(extract_build_commands "$output")

  # Semantic assertions: verify each type routes to its correct repo
  # JAR should go to maven repo
  [[ "$upload_commands" == *"test.jar"*"maven-dev-local"* ]]

  # ZIP should go to generic repo
  [[ "$upload_commands" == *"test.zip"*"generic-dev-local"* ]]

  # Non-sdist TAR.GZ should go to generic repo
  [[ "$upload_commands" == *"test.tar.gz"*"generic-dev-local"* ]]

  # Python wheel should go to pypi repo
  [[ "$upload_commands" == *"aerospike_hello"*"pypi-dev-local"* ]]

  # Python sdist should go to pypi repo, not generic
  [[ "$upload_commands" == *"aerospike-hello-1.0.0.tar.gz"*"pypi-dev-local"* ]]

  # NuGet packages should ONLY go to nuget-dev-local, never generic-dev-local
  local nupkg_in_generic_found=false
  mapfile -t upload_cmd_array < <(echo "$upload_commands")
  for cmd in "${upload_cmd_array[@]}"; do
    if [[ $cmd =~ \.nupkg ]] && [[ $cmd =~ test-project-generic-dev-local ]]; then
      echo "FAIL: NuGet package found in generic repository upload: $cmd" >&2
      nupkg_in_generic_found=true
    fi
  done
  [[ $nupkg_in_generic_found == false ]]

  # Build-publish command should exist
  [[ "$build_commands" == *"build-publish"* ]]
}
