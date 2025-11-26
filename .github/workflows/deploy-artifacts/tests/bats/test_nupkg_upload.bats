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
  
  # Extract NuGet commands
  local nuget_commands
  nuget_commands=$(extract_nuget_commands "$output")
  
  # Verify jf nuget-config command exists
  local nuget_config_found=false
  while IFS= read -r cmd; do
    if [[ $cmd =~ jf\ +nuget-config ]]; then
      nuget_config_found=true
      [[ $cmd =~ test-project-nuget-dev-local ]] || (echo "Invalid repository name in jf nuget-config: $cmd" >&2 && return 1)
      [[ $cmd =~ --repo-resolve= ]] || (echo "Missing --repo-resolve in jf nuget-config: $cmd" >&2 && return 1)
      [[ $cmd =~ --server-id-resolve= ]] || (echo "Missing --server-id-resolve in jf nuget-config: $cmd" >&2 && return 1)
    fi
  done <<< "$nuget_commands"
  
  [[ $nuget_config_found == true ]] || (echo "jf nuget-config command not found" >&2 && return 1)
  
  # Extract jf nuget push commands
  local push_commands
  push_commands=$(echo "$nuget_commands" | grep "jf nuget push" || true)
  
  # Parse push commands into array
  mapfile -t push_cmd_array < <(echo "$push_commands")
  
  # Find NuGet package push commands
  local nupkg_found=false
  local nupkg_commands=()
  for cmd in "${push_cmd_array[@]}"; do
    if [[ $cmd =~ \.nupkg ]]; then
      nupkg_found=true
      
      nupkg_commands+=("$cmd")
      # Verify command structure: jf nuget push <file> -Source Artifactory --build-name=... --build-number=... --project=... --skip-duplicate
      [[ $cmd =~ jf\ +nuget\ +push\ +.*\.nupkg\ +-Source\ +Artifactory ]] || (echo "Invalid jf nuget push command: $cmd" >&2 && return 1)
      [[ $cmd =~ --build-name=test-build ]] || (echo "Missing --build-name flag: $cmd" >&2 && return 1)
      [[ $cmd =~ --build-number=12345-artifacts ]] || (echo "Missing --build-number flag: $cmd" >&2 && return 1)
      [[ $cmd =~ --project=test-project ]] || (echo "Missing --project flag: $cmd" >&2 && return 1)
      [[ $cmd =~ -SkipDuplicate ]] || (echo "Missing -SkipDuplicate flag: $cmd" >&2 && return 1)
    fi
  done

  # Verify we found exactly 2 NuGet package commands (root and subdirectory)
  [[ ${#nupkg_commands[@]} -eq 2 ]] || (echo "Expected 2 NuGet push commands, found ${#nupkg_commands[@]}" >&2 && return 1)

  # Verify NuGet packages were found and processed
  [[ $nupkg_found == true ]] || (echo "NuGet package push not found" >&2 && return 1)
}

@test "NuGet packages use correct jf nuget push commands" {
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")
  
  # Extract NuGet commands
  local nuget_commands
  nuget_commands=$(extract_nuget_commands "$output")
  
  # Verify jf nuget push commands use correct flags
  local push_commands
  push_commands=$(echo "$nuget_commands" | grep "jf nuget push.*\.nupkg" || true)
  
  if [[ -n "$push_commands" ]]; then
    while IFS= read -r cmd; do
      [[ $cmd =~ -Source\ +Artifactory ]] || (echo "jf nuget push missing -Source Artifactory: $cmd" >&2 && return 1)
      [[ $cmd =~ --build-name=test-build ]] || (echo "jf nuget push missing --build-name: $cmd" >&2 && return 1)
      [[ $cmd =~ --build-number=12345-artifacts ]] || (echo "jf nuget push missing --build-number: $cmd" >&2 && return 1)
      [[ $cmd =~ --project=test-project ]] || (echo "jf nuget push missing --project: $cmd" >&2 && return 1)
      [[ $cmd =~ -SkipDuplicate ]] || (echo "jf nuget push missing -SkipDuplicate: $cmd" >&2 && return 1)
    done <<< "$push_commands"
  fi
}

@test "NuGet packages in subdirectories are pushed correctly" {
  # Run entrypoint with dry-run
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

  # Extract NuGet commands
  local nuget_commands
  nuget_commands=$(extract_nuget_commands "$output")

  # Extract jf nuget push commands
  local push_commands
  push_commands=$(echo "$nuget_commands" | grep "jf nuget push.*\.nupkg" || true)

  # Parse commands into array
  mapfile -t push_cmd_array < <(echo "$push_commands")

  # Find ALL NuGet package push commands
  local nupkg_count=0
  local nupkg_in_subdir_found=false
  local wrong_source_found=false

  for cmd in "${push_cmd_array[@]}"; do
    if [[ $cmd =~ \.nupkg ]]; then
      nupkg_count=$((nupkg_count + 1))

      # Check if this is the subdirectory package
      if [[ $cmd =~ nuget/.*\.nupkg ]] || [[ $cmd =~ Aerospike\.HelloWorld ]]; then
        nupkg_in_subdir_found=true
      fi

      # Extract source from command
      local source
      if [[ $cmd =~ -Source\ +([^\ ]+) ]]; then
        source="${BASH_REMATCH[1]}"
      fi

      # Verify ALL NuGet packages use Artifactory source (not ArtifactorySymbols for .nupkg files)
      if [[ "$source" != "Artifactory" ]]; then
        echo "FAIL: NuGet package (.nupkg) pushed to wrong source: $source (expected: Artifactory)" >&2
        echo "Command: $cmd" >&2
        wrong_source_found=true
      fi
    fi
  done

  # Verify we found both NuGet packages (root and subdirectory)
  [[ $nupkg_count -eq 2 ]] || (echo "Expected 2 NuGet packages, found $nupkg_count" >&2 && return 1)

  # Verify we found the subdirectory package
  [[ $nupkg_in_subdir_found == true ]] || (echo "NuGet package in subdirectory not found" >&2 && return 1)

  # CRITICAL: Verify NO packages used wrong source
  [[ $wrong_source_found == false ]] || (echo "NuGet packages were pushed to wrong source" >&2 && return 1)
}

