#!/usr/bin/env bats
# Test multi-distro artifact collection
# Validates that artifacts from multiple matrix builds are correctly merged

setup_file() {
  GIT_ROOT="$(git rev-parse --show-toplevel)"
  TESTS_DIR="$GIT_ROOT/.github/workflows/artifacts-cicd/tests"

  # Default to local fixtures when not running in CI
  if [ -z "${ARTIFACTS_DIR:-}" ]; then
    "$TESTS_DIR/create-test-fixtures.sh"
    export ARTIFACTS_DIR="$TESTS_DIR/test-artifacts/multi-distro"
  fi
}

teardown_file() {
  # Clean up local fixtures (not CI artifacts)
  local fixtures_dir
  fixtures_dir="$(git rev-parse --show-toplevel)/.github/workflows/artifacts-cicd/tests/test-artifacts"
  if [ -d "$fixtures_dir" ]; then
    rm -rf "$fixtures_dir"
  fi
}

setup() {
  if [ ! -d "$ARTIFACTS_DIR" ]; then
    echo "ERROR: Artifacts directory does not exist: $ARTIFACTS_DIR" >&2
    exit 1
  fi
}

@test "All expected distro artifacts are present" {
  # Should have artifacts from el9, jammy, and noble
  local found_el9=0
  local found_jammy=0
  local found_noble=0
  
  # Check for EL9 RPM
  if find "$ARTIFACTS_DIR" -name "*el9*.rpm" | grep -q .; then
    found_el9=1
  fi
  
  # Check for Jammy DEB
  if find "$ARTIFACTS_DIR" -name "*ubuntu22.04*.deb" -o -name "*jammy*.deb" | grep -q .; then
    found_jammy=1
  fi
  
  # Check for Noble DEB
  if find "$ARTIFACTS_DIR" -name "*ubuntu24.04*.deb" -o -name "*noble*.deb" | grep -q .; then
    found_noble=1
  fi
  
  echo "Found EL9: $found_el9, Jammy: $found_jammy, Noble: $found_noble"
  
  [ "$found_el9" -eq 1 ]
  [ "$found_jammy" -eq 1 ]
  [ "$found_noble" -eq 1 ]
}

@test "Artifact count matches expected matrix size" {
  # 3 distros (el9, jammy, noble) = 3 packages
  local artifact_count
  artifact_count=$(find "$ARTIFACTS_DIR" \( -name "*.deb" -o -name "*.rpm" \) | wc -l)
  
  echo "Found $artifact_count artifacts"
  [ "$artifact_count" -eq 3 ]
}

@test "No duplicate artifacts exist" {
  # Get all artifact filenames and check for duplicates
  local duplicates
  duplicates=$(find "$ARTIFACTS_DIR" \( -name "*.deb" -o -name "*.rpm" \) -exec basename {} \; | sort | uniq -d)
  
  if [ -n "$duplicates" ]; then
    echo "Found duplicate artifacts:"
    echo "$duplicates"
    return 1
  fi
  
  return 0
}

@test "All artifacts have correct naming convention" {
  # DEB: name_version_distro_arch.deb
  # RPM: name-version-release.distro.arch.rpm
  
  local invalid_names=""
  
  # Check DEBs
  while IFS= read -r deb; do
    local basename
    basename=$(basename "$deb")
    # Should match pattern: hi_1.0.0-test_ubuntu*.deb
    if ! echo "$basename" | grep -qE '^hi_[0-9]+\.[0-9]+\.[0-9]+-test_(ubuntu|debian)[^_]+_x86_64\.deb$'; then
      invalid_names="$invalid_names\n  Invalid DEB: $basename"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.deb")
  
  # Check RPMs
  while IFS= read -r rpm; do
    local basename
    basename=$(basename "$rpm")
    # Should match pattern: hi-1.0.0-test-1.el9.x86_64.rpm
    if ! echo "$basename" | grep -qE '^hi-[0-9]+\.[0-9]+\.[0-9]+-test-[0-9]+\.(el|amzn)[^.]+\.x86_64\.rpm$'; then
      invalid_names="$invalid_names\n  Invalid RPM: $basename"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.rpm")
  
  if [ -n "$invalid_names" ]; then
    echo "Found artifacts with invalid naming:"
    echo -e "$invalid_names"
    return 1
  fi
  
  return 0
}

@test "All artifacts are non-empty files" {
  local empty_files=""
  
  while IFS= read -r artifact; do
    if [ ! -s "$artifact" ]; then
      empty_files="$empty_files\n  Empty file: $(basename "$artifact")"
    fi
  done < <(find "$ARTIFACTS_DIR" \( -name "*.deb" -o -name "*.rpm" \))
  
  if [ -n "$empty_files" ]; then
    echo "Found empty artifact files:"
    echo -e "$empty_files"
    return 1
  fi
  
  return 0
}

@test "Artifacts have reasonable file sizes" {
  # Each artifact should be at least 1KB (actual packages should be larger)
  local min_size=1024
  local small_files=""
  
  while IFS= read -r artifact; do
    local size
    size=$(stat -c%s "$artifact" 2>/dev/null || stat -f%z "$artifact" 2>/dev/null)
    if [ "$size" -lt "$min_size" ]; then
      small_files="$small_files\n  Too small: $(basename "$artifact") ($size bytes)"
    fi
  done < <(find "$ARTIFACTS_DIR" \( -name "*.deb" -o -name "*.rpm" \))
  
  if [ -n "$small_files" ]; then
    echo "Found suspiciously small artifacts:"
    echo -e "$small_files"
    return 1
  fi
  
  return 0
}

@test "No artifacts were lost during collection" {
  # Verify we didn't lose any artifacts during the merge process
  # This is a smoke test - the count test above is more specific
  
  local total_artifacts
  total_artifacts=$(find "$ARTIFACTS_DIR" \( -name "*.deb" -o -name "*.rpm" \) | wc -l)
  
  echo "Total artifacts collected: $total_artifacts"
  
  # Should have at least 1 artifact (sanity check)
  [ "$total_artifacts" -ge 1 ]
}

@test "Artifact directory structure is flat or properly organized" {
  # Check if artifacts are in a flat structure or organized by type
  # Both are acceptable, but no orphaned files in weird locations
  
  local all_artifacts
  all_artifacts=$(find "$ARTIFACTS_DIR" \( -name "*.deb" -o -name "*.rpm" \))
  
  # Each artifact should be directly in ARTIFACTS_DIR or in a known subdirectory
  local invalid_paths=""
  
  while IFS= read -r artifact; do
    local relative_path="${artifact#$ARTIFACTS_DIR/}"
    local depth
    depth=$(echo "$relative_path" | tr -cd '/' | wc -c)
    
    # Allow depth 0 (flat) or depth 1 (organized in subdirs)
    if [ "$depth" -gt 1 ]; then
      invalid_paths="$invalid_paths\n  Too deep: $relative_path"
    fi
  done <<< "$all_artifacts"
  
  if [ -n "$invalid_paths" ]; then
    echo "Found artifacts in unexpected locations:"
    echo -e "$invalid_paths"
    return 1
  fi
  
  return 0
}
