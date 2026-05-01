#!/usr/bin/env bats
# Test Java artifact upload with validation

# Get absolute paths - use git root to find helpers
GIT_ROOT="$(git rev-parse --show-toplevel)"
DEPLOY_ARTIFACTS_DIR="$GIT_ROOT/.github/workflows/deploy-artifacts"
HELPERS_DIR="$DEPLOY_ARTIFACTS_DIR/tests/helpers"

# Load helper files
load "$HELPERS_DIR/setup.bash"
load "$HELPERS_DIR/command_parsers.bash"
load "$HELPERS_DIR/assertions.bash"

setup_file() {
  setup_test_artifacts
  
  # Verify expected Java artifact fixtures exist
  local -a expected_jars=(
    "$BUILD_ARTIFACTS_DIR/test.jar"
  )
  
  local missing=0
  
  for jar in "${expected_jars[@]}"; do
    if [[ ! -f "$jar" ]]; then
      echo "Error: Missing expected JAR fixture: $jar" >&2
      missing=1
    fi
  done
  
  if [[ $missing -eq 1 ]]; then
    echo "Test fixtures are incomplete. Please check create-test-fixtures.sh" >&2
    return 1
  fi
  
  # Verify we have the expected count
  local actual_jar_count
  actual_jar_count=$(find "$BUILD_ARTIFACTS_DIR" -name "*.jar" -type f | wc -l)
  
  if [[ $actual_jar_count -ne ${#expected_jars[@]} ]]; then
    echo "Warning: Expected ${#expected_jars[@]} JAR files but found $actual_jar_count" >&2
  fi
}

teardown_file() {
  teardown_test_artifacts
}

@test "Java artifacts are uploaded correctly" {
  # Run entrypoint with dry-run
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")
  
  # Extract upload commands
  local upload_commands
  upload_commands=$(extract_upload_commands "$output")
  
  # Parse commands into array
  mapfile -t upload_cmd_array < <(echo "$upload_commands")
  
  # Find Java artifact upload commands.
  # Skip .md5/.sha1 sidecar uploads: they intentionally omit --build-name and
  # --build-number (JFrog absorbs them as parent metadata, and a build-info
  # entry would later cause create-release-bundle to 422). Their build-info
  # opt-out is asserted in a dedicated test below.
  local jar_found=false
  for cmd in "${upload_cmd_array[@]}"; do
    if [[ $cmd =~ \.jar ]] && [[ ! $cmd =~ \.jar\.(md5|sha1)([[:space:]]|$) ]]; then
      jar_found=true

      # Java artifacts go to Maven repo
      local expected_repo="test-project-maven-dev-local"

      # Extract filename from command
      local filename
      if [[ $cmd =~ ([^/]+\.jar) ]]; then
        filename="${BASH_REMATCH[1]}"
      fi

      # Validate command structure with Maven target-props
      assert_upload_command_valid "$cmd" "$filename" "$expected_repo" \
        "version=v1.0.0;group_id=com.example.test;package_name=test" \
        "test-build" "12345-artifacts" "test-project"
    fi
  done
  
  # Verify Java artifacts were found and processed
  [[ $jar_found == true ]] || (echo "Java artifact upload not found" >&2 && return 1)
}

@test "Java artifacts preserve directory structure" {
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")
  
  # Extract upload commands
  local upload_commands
  upload_commands=$(extract_upload_commands "$output")
  
  # Check that --flat=false is present for Java uploads
  local jar_commands
  jar_commands=$(echo "$upload_commands" | grep -E "\.jar" || true)
  
  if [[ -n "$jar_commands" ]]; then
    while IFS= read -r cmd; do
      [[ $cmd == *"--flat=false"* ]] || (echo "Java upload missing --flat=false: $cmd" >&2 && return 1)
    done <<< "$jar_commands"
  fi
}

@test "Java artifacts are not skipped" {
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

  # Verify "Processing JAR:" messages appear for JAR files
  [[ $output == *"Processing JAR:"* ]] || (echo "JAR processing messages not found" >&2 && return 1)

  # Extract upload commands and verify JAR is present
  local upload_commands
  upload_commands=$(extract_upload_commands "$output")

  [[ $upload_commands == *".jar"* ]] || (echo "JAR file upload command not found" >&2 && return 1)
}

@test "Maven companions (pom, .md5, .sha1, .asc) upload to maven repo" {
  # Regression for INFRA-405's companion-model refactor: .pom and checksum
  # sidecars share the JAR's stem, so the generic suffix-append companion
  # logic can't find them and they fall through to the generic repo. They
  # must travel with the JAR into <project>-maven-dev-local.
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

  local upload_commands
  upload_commands=$(extract_upload_commands "$output")

  local expected_repo="test-project-maven-dev-local"
  local f
  for f in test.jar test.pom \
           test.jar.asc test.pom.asc \
           test.jar.md5 test.jar.sha1 test.pom.md5 test.pom.sha1; do
    local cmd
    # Match the file as the source argument to jf rt upload (whitespace-bounded)
    # so e.g. "test.jar" doesn't match "test.jar.asc".
    cmd=$(echo "$upload_commands" | grep -E "[/[:space:]]${f}[[:space:]]" || true)
    [[ -n $cmd ]] || (echo "Missing maven upload for $f" >&2 && return 1)
    [[ $cmd == *"$expected_repo"* ]] || \
      (echo "$f did not upload to $expected_repo: $cmd" >&2 && return 1)
  done
}

@test "Signed checksums (.md5.asc, .sha1.asc) are NOT uploaded" {
  # Maven Central convention: .md5 and .sha1 are not signed, so .md5.asc and
  # .sha1.asc files must not appear in the deployed artifact set. The sign
  # step in shared-workflows currently signs every file indiscriminately,
  # producing these as a side effect. This test pins the deploy step's
  # contract: it filters them out before upload regardless of what the sign
  # step produced.
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

  local upload_commands
  upload_commands=$(extract_upload_commands "$output")

  local f
  for f in test.jar.md5.asc test.jar.sha1.asc test.pom.md5.asc test.pom.sha1.asc; do
    local cmd
    cmd=$(echo "$upload_commands" | grep -E "[/[:space:]]${f}[[:space:]]" || true)
    [[ -z $cmd ]] || \
      (echo "$f must NOT be uploaded (Maven Central does not sign checksums): $cmd" >&2 && return 1)
  done
}

@test "Maven sidecars (.md5, .sha1) upload without build-info" {
  # JFrog's checksum-deploy interception absorbs .md5/.sha1 uploads as
  # metadata on the parent artifact instead of storing them as files. If we
  # record the upload in the build-info, create-release-bundle later fails
  # with 422 Unprocessable Entity ("Unresolvable build artifact") because the
  # sidecar isn't a real stored artifact. The fix omits --build-name and
  # --build-number for these uploads.
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

  local upload_commands
  upload_commands=$(extract_upload_commands "$output")

  local f
  for f in test.jar.md5 test.jar.sha1 test.pom.md5 test.pom.sha1; do
    local cmd
    cmd=$(echo "$upload_commands" | grep -E "[/[:space:]]${f}[[:space:]]" || true)
    [[ -n $cmd ]] || (echo "Missing upload for $f" >&2 && return 1)
    [[ $cmd != *"--build-name"* ]] || \
      (echo "$f must not include --build-name in upload command: $cmd" >&2 && return 1)
    [[ $cmd != *"--build-number"* ]] || \
      (echo "$f must not include --build-number in upload command: $cmd" >&2 && return 1)
  done
}

@test "JAR and POM uploads include build-info" {
  # The base artifacts (.jar, .pom) and their .asc signatures must remain in
  # the build-info so they are included in release bundles. This pairs with
  # the previous test: only the .md5/.sha1 sidecars opt out.
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

  local upload_commands
  upload_commands=$(extract_upload_commands "$output")

  local f
  for f in test.jar test.pom test.jar.asc test.pom.asc; do
    local cmd
    cmd=$(echo "$upload_commands" | grep -E "[/[:space:]]${f}[[:space:]]" || true)
    [[ -n $cmd ]] || (echo "Missing upload for $f" >&2 && return 1)
    [[ $cmd == *"--build-name"* ]] || \
      (echo "$f must include --build-name in upload command: $cmd" >&2 && return 1)
    [[ $cmd == *"--build-number"* ]] || \
      (echo "$f must include --build-number in upload command: $cmd" >&2 && return 1)
  done
}

@test "Maven sidecars (.md5, .sha1) do not leak into the generic repo" {
  # Regression test: process_jar copies (not moves) checksum sidecars into the
  # structured jar tree, so structure_generic_files would also pick them up
  # from build-artifacts/ unless their extensions are claimed in
  # get_known_extensions. If they leak into <project>-generic-dev-local, JFrog's
  # checksum-deploy interception 404s because the base .jar/.pom isn't in the
  # generic repo at the same path.
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

  local upload_commands
  upload_commands=$(extract_upload_commands "$output")

  local generic_repo="test-project-generic-dev-local"
  local f
  for f in test.jar.md5 test.jar.sha1 test.pom.md5 test.pom.sha1; do
    local generic_cmd
    generic_cmd=$(echo "$upload_commands" | grep -E "[/[:space:]]${f}[[:space:]]" | grep -F "$generic_repo" || true)
    [[ -z $generic_cmd ]] || \
      (echo "$f leaked into $generic_repo: $generic_cmd" >&2 && return 1)
  done
}

@test "Maven companions upload base files before checksums" {
  # JFrog's checksum-deploy interception fires on .md5/.sha1/.sha256 uploads
  # and looks for the corresponding base file at the same path in the same
  # repo. If the base file isn't there yet, the upload returns 404. The
  # _upload_jar_entry loop must therefore order base files before sidecars.
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

  local upload_commands
  upload_commands=$(extract_upload_commands "$output")

  # Position of each filename's first occurrence in the upload sequence.
  local jar_pos pom_pos
  local jar_md5_pos jar_sha1_pos pom_md5_pos pom_sha1_pos
  jar_pos=$(echo "$upload_commands"      | grep -nE "[/[:space:]]test\.jar[[:space:]]"      | head -1 | cut -d: -f1)
  pom_pos=$(echo "$upload_commands"      | grep -nE "[/[:space:]]test\.pom[[:space:]]"      | head -1 | cut -d: -f1)
  jar_md5_pos=$(echo "$upload_commands"  | grep -nE "[/[:space:]]test\.jar\.md5[[:space:]]"  | head -1 | cut -d: -f1)
  jar_sha1_pos=$(echo "$upload_commands" | grep -nE "[/[:space:]]test\.jar\.sha1[[:space:]]" | head -1 | cut -d: -f1)
  pom_md5_pos=$(echo "$upload_commands"  | grep -nE "[/[:space:]]test\.pom\.md5[[:space:]]"  | head -1 | cut -d: -f1)
  pom_sha1_pos=$(echo "$upload_commands" | grep -nE "[/[:space:]]test\.pom\.sha1[[:space:]]" | head -1 | cut -d: -f1)

  [[ -n $jar_pos && -n $jar_md5_pos  && $jar_pos -lt $jar_md5_pos  ]] || \
    (echo "test.jar must upload before test.jar.md5  (jar=$jar_pos, jar.md5=$jar_md5_pos)" >&2 && return 1)
  [[ -n $jar_pos && -n $jar_sha1_pos && $jar_pos -lt $jar_sha1_pos ]] || \
    (echo "test.jar must upload before test.jar.sha1 (jar=$jar_pos, jar.sha1=$jar_sha1_pos)" >&2 && return 1)
  [[ -n $pom_pos && -n $pom_md5_pos  && $pom_pos -lt $pom_md5_pos  ]] || \
    (echo "test.pom must upload before test.pom.md5  (pom=$pom_pos, pom.md5=$pom_md5_pos)" >&2 && return 1)
  [[ -n $pom_pos && -n $pom_sha1_pos && $pom_pos -lt $pom_sha1_pos ]] || \
    (echo "test.pom must upload before test.pom.sha1 (pom=$pom_pos, pom.sha1=$pom_sha1_pos)" >&2 && return 1)
}

@test "Standalone POM is structured and added to the manifest" {
  # Diagnostic: confirms structure_standalone_poms ran for the no-JAR case
  # before checking the upload step. Splits failure modes (structuring vs
  # uploading) so a regression points to the right layer.
  run_entrypoint_dry_run >/dev/null 2>&1 || true

  local manifest_path="structured_build_artifacts/.manifest"
  [[ -f $manifest_path ]] || (echo "Manifest not produced" >&2 && return 1)

  grep -qE 'standalone-bom\.pom\b.*\bjar$' "$manifest_path" || \
    (echo "standalone-bom.pom missing from manifest:" >&2 && cat "$manifest_path" >&2 && return 1)

  local structured_pom
  structured_pom=$(awk -F'\t' '$2=="jar" && $1 ~ /standalone-bom\.pom$/ {print $1; exit}' "$manifest_path")
  [[ -f $structured_pom ]] || \
    (echo "Manifest names $structured_pom but the file is missing" >&2 && return 1)
}

@test "Standalone POM (no JAR) and its sidecars upload to maven repo" {
  # BOM/parent POMs ship without a JAR. structure_standalone_poms must copy the
  # .pom.md5/.pom.sha1/.pom.asc siblings into the structured tree so they reach
  # the maven repo; otherwise they fall through to structure_generic_files which
  # excludes *.md5/*.sha1 (reserved for JAR processing).
  local output
  output=$(run_entrypoint_dry_run "test-project" "test-build" "v1.0.0" "12345" "12345-metadata")

  local upload_commands
  upload_commands=$(extract_upload_commands "$output")

  local expected_repo="test-project-maven-dev-local"
  local f
  for f in standalone-bom.pom \
           standalone-bom.pom.asc \
           standalone-bom.pom.md5 \
           standalone-bom.pom.sha1; do
    local cmd
    cmd=$(echo "$upload_commands" | grep -E "[/[:space:]]${f}[[:space:]]" || true)
    if [[ -z $cmd ]]; then
      # Print all upload commands to make the failure self-diagnosing in CI logs.
      echo "Missing upload for $f. Full upload command list:" >&2
      echo "$upload_commands" >&2
      return 1
    fi
    [[ $cmd == *"$expected_repo"* ]] || \
      (echo "$f did not upload to $expected_repo: $cmd" >&2 && return 1)
  done
}

@test "parse_jf_upload_command tolerates ANSI and leading spaces before jf rt upload" {
  local cmd parse_output
  cmd=$'\033[0;32m   jf rt upload ./pkg.deb myrepo --flat=false --build-name=b --build-number=1-artifacts --project=p'
  parse_output=$(parse_jf_upload_command "$cmd")
  echo "$parse_output" | grep -q '^file_path=./pkg.deb$'
  echo "$parse_output" | grep -q '^repo=myrepo$'
}

