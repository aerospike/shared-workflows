#!/usr/bin/env bats
# Upload-only and publish-only deploy modes for parallel platform deploys

GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_ARTIFACTS_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts"
HELPERS_DIR="$DEPLOY_ARTIFACTS_DIR/tests/helpers"

load "$HELPERS_DIR/setup.bash"

setup_file() {
  setup_test_artifacts
}

teardown_file() {
  teardown_test_artifacts
}

@test "skip-publish-build-info uploads artifacts without publishing build info" {
  cd "$TEST_DIR" || exit 1
  "$DEPLOY_ARTIFACTS_DIR/detect_types.sh" --artifacts-dir "$BUILD_ARTIFACTS_DIR" >/dev/null 2>&1

  run "$DEPLOY_ARTIFACTS_DIR/entrypoint.sh" \
    test-project test-build v1.0.0 12345 12345-buildinfo \
    --dry-run \
    --skip-publish-build-info \
    2>&1

  [[ $status -eq 0 ]]
  [[ $output == *"Skipping build-info publish (upload-only mode)"* ]]
  [[ $output == *"jf rt upload"* ]]
  [[ $output != *"jf rt build-publish test-build 12345 --project=test-project"* ]]
}

@test "publish-build-info-only publishes build info without requiring build-artifacts" {
  run "$DEPLOY_ARTIFACTS_DIR/entrypoint.sh" \
    test-project test-build v1.0.0 12345 12345-buildinfo \
    --dry-run \
    --publish-build-info-only \
    2>&1

  [[ $status -eq 0 ]]
  [[ $output == *"Would publish build info to JFrog Artifactory"* ]]
  [[ $output == *"jf rt build-publish test-build 12345-artifacts"* ]]
  [[ $output == *"jf rt build-publish test-build 12345"* ]]
  [[ $output != *"jf rt upload"* ]]
}

@test "skip-publish and publish-only together is rejected" {
  run "$DEPLOY_ARTIFACTS_DIR/entrypoint.sh" \
    test-project test-build v1.0.0 12345 12345-buildinfo \
    --skip-publish-build-info \
    --publish-build-info-only \
    2>&1

  [[ $status -ne 0 ]]
  [[ $output == *"Cannot use --skip-publish-build-info and --publish-build-info-only together"* ]]
}
