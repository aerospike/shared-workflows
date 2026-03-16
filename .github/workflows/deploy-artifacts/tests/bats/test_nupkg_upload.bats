#!/usr/bin/env bats

# Get absolute paths - use git root to find helpers
GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_ARTIFACTS_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts"
HELPERS_DIR="$DEPLOY_ARTIFACTS_DIR/tests/helpers"

load "$HELPERS_DIR/setup.bash"
load "$HELPERS_DIR/command_parsers.bash"
load "$HELPERS_DIR/assertions.bash"

# Source package_utils.sh for get_nupkg_metadata
# shellcheck disable=SC1091
source "$DEPLOY_ARTIFACTS_DIR/package_utils.sh"

setup_file() {
  setup_test_artifacts
  
  # Verify expected NuGet package fixtures exist (root and subdirectory)
  local -a expected_nupkgs=(
    "$BUILD_ARTIFACTS_DIR/Aerospike.Client.8.0.2.nupkg"
    "$BUILD_ARTIFACTS_DIR/nuget/Aerospike.HelloWorld.1.0.0.nupkg"
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
  
  # Extract NuGet upload commands
  local nuget_commands
  nuget_commands=$(extract_nuget_commands "$output")
  
  # Parse commands into array
  mapfile -t nuget_cmd_array < <(echo "$nuget_commands")
  
  # Find NuGet primary package upload commands (exclude .asc companions)
  local nupkg_found=false
  local nupkg_commands=()
  for cmd in "${nuget_cmd_array[@]}"; do
    if [[ $cmd =~ \.(nupkg|snupkg)[[:space:]] ]]; then
      nupkg_found=true

      nupkg_commands+=("$cmd")
      # Verify command structure: jf rt upload <file> <repo>/<pkgname>/<version>/<filename> --build-name=... --build-number=... --project=...
      [[ $cmd =~ jf\ +rt\ +upload\ +.*\.(nupkg|snupkg) ]] || (echo "Invalid jf rt upload command: $cmd" >&2 && return 1)
      [[ $cmd =~ test-project-nuget-dev-local ]] || (echo "Missing or incorrect repository name: $cmd" >&2 && return 1)
      [[ $cmd =~ --build-name=test-build ]] || (echo "Missing --build-name flag: $cmd" >&2 && return 1)
      [[ $cmd =~ --build-number=12345-artifacts ]] || (echo "Missing --build-number flag: $cmd" >&2 && return 1)
      [[ $cmd =~ --project=test-project ]] || (echo "Missing --project flag: $cmd" >&2 && return 1)
      # Verify NuGet layout structure: <pkgname>/<version>/<filename>
      [[ $cmd =~ test-project-nuget-dev-local/[^/]+/[^/]+/.*\.(nupkg|snupkg) ]] || (echo "Invalid NuGet layout path: $cmd" >&2 && return 1)
    fi
  done

  # Verify we found exactly 3 NuGet package commands (2 nupkg + 1 snupkg)
  [[ ${#nupkg_commands[@]} -eq 3 ]] || (echo "Expected 3 NuGet upload commands, found ${#nupkg_commands[@]}" >&2 && return 1)

  # Verify NuGet packages were found and processed
  [[ $nupkg_found == true ]] || (echo "NuGet package upload not found" >&2 && return 1)
}

@test "NuGet packages use correct jf rt upload commands" {
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")
  
  # Extract NuGet commands
  local nuget_commands
  nuget_commands=$(extract_nuget_commands "$output")
  
  # Verify jf rt upload commands for primary packages (not .asc companions) use correct flags and layout
  local upload_commands
  upload_commands=$(echo "$nuget_commands" | grep -E '\.(nupkg|snupkg)[[:space:]]' || true)

  if [[ -n "$upload_commands" ]]; then
    while IFS= read -r cmd; do
      [[ $cmd =~ jf\ +rt\ +upload ]] || (echo "Not a jf rt upload command: $cmd" >&2 && return 1)
      [[ $cmd =~ test-project-nuget-dev-local ]] || (echo "Missing or incorrect repository name: $cmd" >&2 && return 1)
      [[ $cmd =~ --build-name=test-build ]] || (echo "jf rt upload missing --build-name: $cmd" >&2 && return 1)
      [[ $cmd =~ --build-number=12345-artifacts ]] || (echo "jf rt upload missing --build-number: $cmd" >&2 && return 1)
      [[ $cmd =~ --project=test-project ]] || (echo "jf rt upload missing --project: $cmd" >&2 && return 1)
      # Verify NuGet layout structure: <pkgname>/<version>/<filename>
      [[ $cmd =~ test-project-nuget-dev-local/[^/]+/[^/]+/.*\.(nupkg|snupkg) ]] || (echo "Invalid NuGet layout path: $cmd" >&2 && return 1)
    done <<< "$upload_commands"
  fi
}

@test "NuGet packages in subdirectories are uploaded correctly" {
  # Run entrypoint with dry-run
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

  # Extract NuGet commands
  local nuget_commands
  nuget_commands=$(extract_nuget_commands "$output")

  # Parse commands into array
  mapfile -t nuget_cmd_array < <(echo "$nuget_commands")

  # Find ALL NuGet primary package upload commands (exclude .asc companions)
  local nupkg_count=0
  local nupkg_in_subdir_found=false
  local wrong_repo_found=false

  for cmd in "${nuget_cmd_array[@]}"; do
    if [[ $cmd =~ \.(nupkg|snupkg)[[:space:]] ]]; then
      nupkg_count=$((nupkg_count + 1))

      # Check if this is the subdirectory package (Aerospike.HelloWorld)
      if [[ $cmd =~ Aerospike\.HelloWorld ]]; then
        nupkg_in_subdir_found=true
      fi

      # Verify correct repository
      if [[ ! $cmd =~ test-project-nuget-dev-local ]]; then
        wrong_repo_found=true
      fi
    fi
  done

  # Verify we found all NuGet packages (2 nupkg + 1 snupkg)
  [[ $nupkg_count -eq 3 ]] || (echo "Expected 3 NuGet packages, found $nupkg_count" >&2 && return 1)

  # Verify we found the subdirectory package
  [[ $nupkg_in_subdir_found == true ]] || (echo "NuGet package in subdirectory not found" >&2 && return 1)

  # CRITICAL: Verify NO packages used wrong repository
  [[ $wrong_repo_found == false ]] || (echo "NuGet packages were uploaded to wrong repository" >&2 && return 1)
}

@test "NuGet metadata parsing extracts package name and version correctly" {
  # Test case 1: Standard version format
  local -a metadata
  read -r -a metadata <<< "$(get_nupkg_metadata "Aerospike.HelloWorld.1.0.0.nupkg")"
  [[ "${metadata[0]}" == "Aerospike.HelloWorld" ]] || (echo "Failed to extract package name from Aerospike.HelloWorld.1.0.0.nupkg: got ${metadata[0]}" >&2 && return 1)
  [[ "${metadata[1]}" == "1.0.0" ]] || (echo "Failed to extract version from Aerospike.HelloWorld.1.0.0.nupkg: got ${metadata[1]}" >&2 && return 1)

  # Test case 2: Version with pre-release suffix
  read -r -a metadata <<< "$(get_nupkg_metadata "MyPackage.2.3.4-beta.nupkg")"
  [[ "${metadata[0]}" == "MyPackage" ]] || (echo "Failed to extract package name from MyPackage.2.3.4-beta.nupkg: got ${metadata[0]}" >&2 && return 1)
  [[ "${metadata[1]}" == "2.3.4-beta" ]] || (echo "Failed to extract version from MyPackage.2.3.4-beta.nupkg: got ${metadata[1]}" >&2 && return 1)

  # Test case 3: Package with sub-package name
  read -r -a metadata <<< "$(get_nupkg_metadata "Package.SubPackage.1.0.0.1.nupkg")"
  [[ "${metadata[0]}" == "Package.SubPackage" ]] || (echo "Failed to extract package name from Package.SubPackage.1.0.0.1.nupkg: got ${metadata[0]}" >&2 && return 1)
  [[ "${metadata[1]}" == "1.0.0.1" ]] || (echo "Failed to extract version from Package.SubPackage.1.0.0.1.nupkg: got ${metadata[1]}" >&2 && return 1)

  # Test case 4: Symbol package
  read -r -a metadata <<< "$(get_nupkg_metadata "TestPackage.3.2.1.snupkg")"
  [[ "${metadata[0]}" == "TestPackage" ]] || (echo "Failed to extract package name from TestPackage.3.2.1.snupkg: got ${metadata[0]}" >&2 && return 1)
  [[ "${metadata[1]}" == "3.2.1" ]] || (echo "Failed to extract version from TestPackage.3.2.1.snupkg: got ${metadata[1]}" >&2 && return 1)

  # Test case 5: Version with build metadata
  read -r -a metadata <<< "$(get_nupkg_metadata "Some.Package.5.6.7-alpha.1.nupkg")"
  [[ "${metadata[0]}" == "Some.Package" ]] || (echo "Failed to extract package name from Some.Package.5.6.7-alpha.1.nupkg: got ${metadata[0]}" >&2 && return 1)
  [[ "${metadata[1]}" == "5.6.7-alpha.1" ]] || (echo "Failed to extract version from Some.Package.5.6.7-alpha.1.nupkg: got ${metadata[1]}" >&2 && return 1)
}

