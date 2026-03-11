#!/usr/bin/env bats
# Test mixed artifact types (native + dotnet)
# Validates that different artifact types can coexist and are properly handled

setup_file() {
  GIT_ROOT="$(git rev-parse --show-toplevel)"
  TESTS_DIR="$GIT_ROOT/.github/workflows/artifacts-cicd/tests"

  # Default to local fixtures when not running in CI
  if [ -z "${ARTIFACTS_DIR:-}" ]; then
    "$TESTS_DIR/create-test-fixtures.sh"
    export ARTIFACTS_DIR="$TESTS_DIR/test-artifacts/mixed-matrix"
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

@test "Both native and NuGet artifacts are present" {
  local has_native=0
  local has_nuget=0
  
  # Check for native packages (DEB or RPM)
  if find "$ARTIFACTS_DIR" \( -name "*.deb" -o -name "*.rpm" \) | grep -q .; then
    has_native=1
  fi
  
  # Check for NuGet packages
  if find "$ARTIFACTS_DIR" -name "*.nupkg" | grep -q .; then
    has_nuget=1
  fi
  
  echo "Found native packages: $has_native"
  echo "Found NuGet packages: $has_nuget"
  
  [ "$has_native" -eq 1 ]
  [ "$has_nuget" -eq 1 ]
}

@test "Artifact count matches expected matrix size" {
  # 1 native (jammy DEB) + 1 dotnet (nupkg) = 2 packages
  local artifact_count
  artifact_count=$(find "$ARTIFACTS_DIR" \( -name "*.deb" -o -name "*.rpm" -o -name "*.nupkg" \) | wc -l)
  
  echo "Found $artifact_count artifacts"
  [ "$artifact_count" -eq 2 ]
}

@test "NuGet package has correct naming convention" {
  # NuGet: PackageName.Version.nupkg
  local invalid_names=""
  
  while IFS= read -r nupkg; do
    local basename
    basename=$(basename "$nupkg")
    # Should match pattern: Aerospike.HelloWorld.1.0.0-test.nupkg or similar
    if ! echo "$basename" | grep -qE '^[A-Za-z]+\.[A-Za-z]+\.[0-9]+\.[0-9]+\.[0-9]+-test\.nupkg$'; then
      invalid_names="$invalid_names\n  Invalid NuGet: $basename"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.nupkg")
  
  if [ -n "$invalid_names" ]; then
    echo "Found NuGet packages with invalid naming:"
    echo -e "$invalid_names"
    return 1
  fi
  
  return 0
}

@test "Native package has correct naming convention" {
  # DEB: name_version_distro_arch.deb
  # RPM: name-version-release.distro.arch.rpm
  local invalid_names=""
  
  # Check DEBs
  while IFS= read -r deb; do
    local basename
    basename=$(basename "$deb")
    if ! echo "$basename" | grep -qE '^hi_[0-9]+\.[0-9]+\.[0-9]+-test_(ubuntu|debian)[^_]+_x86_64\.deb$'; then
      invalid_names="$invalid_names\n  Invalid DEB: $basename"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.deb")
  
  # Check RPMs
  while IFS= read -r rpm; do
    local basename
    basename=$(basename "$rpm")
    if ! echo "$basename" | grep -qE '^hi-[0-9]+\.[0-9]+\.[0-9]+-test-[0-9]+\.(el|amzn)[^.]+\.x86_64\.rpm$'; then
      invalid_names="$invalid_names\n  Invalid RPM: $basename"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.rpm")
  
  if [ -n "$invalid_names" ]; then
    echo "Found native packages with invalid naming:"
    echo -e "$invalid_names"
    return 1
  fi
  
  return 0
}

@test "No artifact type collision or overwrite" {
  # Verify that we have distinct artifacts with no duplicates
  local all_artifacts
  all_artifacts=$(find "$ARTIFACTS_DIR" \( -name "*.deb" -o -name "*.rpm" -o -name "*.nupkg" \) -exec basename {} \;)
  
  local unique_count
  unique_count=$(echo "$all_artifacts" | sort -u | wc -l)
  
  local total_count
  total_count=$(echo "$all_artifacts" | wc -l)
  
  echo "Total artifacts: $total_count, Unique: $unique_count"
  
  [ "$unique_count" -eq "$total_count" ]
}

@test "All artifacts are valid archive files" {
  # Basic validation that files are actual packages
  local invalid_files=""
  
  # Check DEBs
  while IFS= read -r deb; do
    if ! file "$deb" | grep -q "Debian binary package"; then
      invalid_files="$invalid_files\n  Invalid DEB: $(basename "$deb")"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.deb")
  
  # Check RPMs
  while IFS= read -r rpm; do
    if ! file "$rpm" | grep -qE "(RPM|cpio archive)"; then
      invalid_files="$invalid_files\n  Invalid RPM: $(basename "$rpm")"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.rpm")
  
  # Check NuPkgs (ZIP-based)
  while IFS= read -r nupkg; do
    if ! file "$nupkg" | grep -qE "(Zip archive|Microsoft OOXML)"; then
      invalid_files="$invalid_files\n  Invalid NuPkg: $(basename "$nupkg")"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.nupkg")
  
  if [ -n "$invalid_files" ]; then
    echo "Found invalid package files:"
    echo -e "$invalid_files"
    return 1
  fi
  
  return 0
}

@test "All artifacts are non-empty and reasonable size" {
  # Each artifact should be at least 1KB
  local min_size=1024
  local issues=""
  
  while IFS= read -r artifact; do
    local size
    size=$(stat -c%s "$artifact" 2>/dev/null || stat -f%z "$artifact" 2>/dev/null)
    
    if [ "$size" -lt "$min_size" ]; then
      issues="$issues\n  Too small: $(basename "$artifact") ($size bytes)"
    fi
  done < <(find "$ARTIFACTS_DIR" \( -name "*.deb" -o -name "*.rpm" -o -name "*.nupkg" \))
  
  if [ -n "$issues" ]; then
    echo "Found size issues:"
    echo -e "$issues"
    return 1
  fi
  
  return 0
}

@test "Artifacts from different build types are correctly separated or merged" {
  # Verify that artifacts are organized in a way that makes sense
  # Could be flat or in subdirectories, but should be consistent
  
  local native_paths=""
  local nuget_paths=""
  
  while IFS= read -r artifact; do
    native_paths="$native_paths$(dirname "$artifact")\n"
  done < <(find "$ARTIFACTS_DIR" \( -name "*.deb" -o -name "*.rpm" \))
  
  while IFS= read -r artifact; do
    nuget_paths="$nuget_paths$(dirname "$artifact")\n"
  done < <(find "$ARTIFACTS_DIR" -name "*.nupkg")
  
  # Just verify we found artifacts
  [ -n "$native_paths" ]
  [ -n "$nuget_paths" ]
}

@test "No unexpected file types in artifact collection" {
  # Only .deb, .rpm, and .nupkg files should be present
  local unexpected_files
  unexpected_files=$(find "$ARTIFACTS_DIR" -type f ! \( -name "*.deb" -o -name "*.rpm" -o -name "*.nupkg" \))
  
  if [ -n "$unexpected_files" ]; then
    echo "Found unexpected files in artifact directory:"
    echo "$unexpected_files"
    return 1
  fi
  
  return 0
}
