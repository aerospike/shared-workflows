#!/usr/bin/env bats
# Test DEB and RPM upload commands with validation

# Get absolute paths - use git root to find helpers
GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_ARTIFACTS_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts"
HELPERS_DIR="$DEPLOY_ARTIFACTS_DIR/tests/helpers"

# Load helper files
load "$HELPERS_DIR/setup.bash"
load "$HELPERS_DIR/command_parsers.bash"
load "$HELPERS_DIR/assertions.bash"

# Source package_utils.sh for get_rpm_metadata
# shellcheck disable=SC1091
source "$DEPLOY_ARTIFACTS_DIR/package_utils.sh"

# Helper to get file path from upload command and lookup expected values
get_file_path() {
  local cmd="$1"
  # Extract file path from command
  if [[ $cmd =~ jf\ +rt\ +upload\ +([^\ ]+) ]]; then
    echo "${BASH_REMATCH[1]}"
  fi
}
setup_file() {
  setup_test_artifacts
  
  # Verify all expected test fixtures exist before running tests
  local -a expected_debs=(
    "$BUILD_ARTIFACTS_DIR/test-ubuntu22.04.deb"
    "$BUILD_ARTIFACTS_DIR/nested/dir/test-debian12.deb"
    "$BUILD_ARTIFACTS_DIR/test-all-arch_1.0.0-1ubuntu22.04_all.deb"
  )
  
  local -a expected_rpms=(
    "$BUILD_ARTIFACTS_DIR/test-1.0-2.noarch.rpm"
    "$BUILD_ARTIFACTS_DIR/nested/dir/nested.rpm"
  )
  
  local missing=0
  
  for deb in "${expected_debs[@]}"; do
    if [[ ! -f "$deb" ]]; then
      echo "Error: Missing expected DEB fixture: $deb" >&2
      missing=1
    fi
  done
  
  for rpm in "${expected_rpms[@]}"; do
    if [[ ! -f "$rpm" ]]; then
      echo "Error: Missing expected RPM fixture: $rpm" >&2
      missing=1
    fi
  done
  
  if [[ $missing -eq 1 ]]; then
    echo "Test fixtures are incomplete. Please check create-test-fixtures.sh" >&2
    return 1
  fi
  
  # Count actual DEB/RPM files to ensure we're not testing unexpected files
  local actual_deb_count
  actual_deb_count=$(find "$BUILD_ARTIFACTS_DIR" -name "*.deb" -type f | wc -l)
  local actual_rpm_count
  actual_rpm_count=$(find "$BUILD_ARTIFACTS_DIR" -name "*.rpm" -type f | wc -l)
  
  if [[ $actual_deb_count -ne ${#expected_debs[@]} ]]; then
    echo "Warning: Expected ${#expected_debs[@]} DEB files but found $actual_deb_count" >&2
    echo "This may cause unexpected warnings during test execution" >&2
  fi
  
  if [[ $actual_rpm_count -ne ${#expected_rpms[@]} ]]; then
    echo "Warning: Expected ${#expected_rpms[@]} RPM files but found $actual_rpm_count" >&2
    echo "This may cause unexpected warnings during test execution" >&2
  fi
}

# Lookup expected DEB values by filename pattern
get_deb_expectations() {
  local file_path="$1"
  local filename
  filename=$(basename "$file_path")
  # This isn't very flexible (it will fail if we add more files) but that will force us to change the test if we change the fixture.
  local file_location codename
  case "$filename" in
    *all-arch*ubuntu22.04*)
      file_location="$BUILD_ARTIFACTS_DIR/test-all-arch_1.0.0-1ubuntu22.04_all.deb"
      codename="jammy"
      ;;
    *ubuntu22.04*)
      file_location="$BUILD_ARTIFACTS_DIR/test-ubuntu22.04.deb"
      codename="jammy"
      ;;
    *debian12*)
      file_location="$BUILD_ARTIFACTS_DIR/nested/dir/test-debian12.deb"
      codename="bookworm"
      ;;
    *)
      echo "Error: Unexpected DEB file '$filename' not in test fixture list" >&2
      echo "Update get_deb_expectations() and setup_file() if this is intentional" >&2
      return 1
      ;;
  esac
  
  local arch
  arch=$(dpkg-deb -f "$file_location" Architecture)
  
  local pkgname
  pkgname=$(dpkg-deb -f "$file_location" Package)

  echo "repo=test-project-deb-dev-local"
  echo "codename=$codename"
  echo "arch=$arch"
  echo "props=version=v1.0.0;package_name=$pkgname;deb.distribution=$codename;deb.component=main;deb.architecture=$arch"
}

# Lookup expected RPM values by filename pattern
get_rpm_expectations() {
  local file_path="$1"
  local filename
  filename=$(basename "$file_path")
  # This isn't very flexible (it will fail if we add more files) but that will force us to change the test if we change the fixture.
  local file_location
  case "$filename" in
    test-1.0-2.noarch.rpm)
      file_location="$BUILD_ARTIFACTS_DIR/$filename"
      ;;
    nested.rpm)
      file_location="$BUILD_ARTIFACTS_DIR/nested/dir/$filename"
      ;;
    *)
      echo "Error: Unexpected RPM file '$filename' not in test fixture list" >&2
      echo "Update get_rpm_expectations() and setup_file() if this is intentional" >&2
      return 1
      ;;
  esac
  
  local -a metadata
  read -r -a metadata <<< "$(get_rpm_metadata "$file_location")"
  
  echo "repo=test-project-rpm-dev-local"
  echo "props=version=v1.0.0;package_name=${metadata[0]};rpm.distribution=${metadata[3]};rpm.component=main;rpm.architecture=${metadata[2]}"
}


teardown_file() {
  teardown_test_artifacts
}

@test "DEB and RPM upload commands are valid" {
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")
  
  local upload_commands build_commands
  upload_commands=$(extract_upload_commands "$output")
  build_commands=$(extract_build_commands "$output")
  
  # Semantic check: at least some upload and build commands exist
  [[ -n "$upload_commands" ]]
  [[ -n "$build_commands" ]]
  
  mapfile -t upload_cmd_array < <(echo "$upload_commands")
  mapfile -t build_cmd_array < <(echo "$build_commands")
  
  local deb_count=0 rpm_count=0
  
  for cmd in "${upload_cmd_array[@]}"; do
    local file_path
    file_path=$(get_file_path "$cmd")
    local filename
    filename=$(basename "$file_path")
    
    if [[ "$filename" == *.deb ]]; then
      deb_count=$((deb_count + 1))
      
      local -A exp=()
      local expectations
      expectations=$(get_deb_expectations "$file_path")
      
      while IFS='=' read -r key value; do
        [[ -n "$key" ]] && exp["$key"]="$value"
      done <<< "$expectations"
      
      assert_upload_command_valid "$cmd" "$filename" "${exp[repo]}" "${exp[props]}" \
        "test-build" "12345-artifacts" "test-project"
      
    elif [[ "$filename" == *.rpm ]]; then
      rpm_count=$((rpm_count + 1))
      
      local -A exp=()
      local expectations
      expectations=$(get_rpm_expectations "$file_path")
      
      while IFS='=' read -r key value; do
        [[ -n "$key" ]] && exp["$key"]="$value"
      done <<< "$expectations"
      
      assert_upload_command_valid "$cmd" "$filename" "${exp[repo]}" "${exp[props]}" \
        "test-build" "12345-artifacts" "test-project"
    fi
  done
  
  [[ $deb_count -gt 0 ]] || (echo "No DEB commands found" >&2 && return 1)
  [[ $rpm_count -gt 0 ]] || (echo "No RPM commands found" >&2 && return 1)
  
  local found_publish=false
  for cmd in "${build_cmd_array[@]}"; do
    if [[ $cmd =~ build-publish ]]; then
      assert_build_command_valid "$cmd" "test-build" "12345-artifacts" "test-project"
      found_publish=true
      break
    fi
  done
  
  [[ $found_publish == true ]] || (echo "build-publish command not found" >&2 && return 1)
}

