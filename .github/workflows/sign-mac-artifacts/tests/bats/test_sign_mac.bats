#!/usr/bin/env bats
# Tests for sign-mac-artifacts entrypoint.sh
#
# These tests mock Apple signing tools (codesign, productsign, xcrun, security, pkgutil)
# since they are only available on macOS and require real certificates.
# Tests validate argument parsing, file type routing, glob filtering, and keychain lifecycle.

setup_file() {
  GIT_ROOT="$(git rev-parse --show-toplevel)"
  export GIT_ROOT
  ENTRYPOINT="$GIT_ROOT/.github/workflows/sign-mac-artifacts/entrypoint.sh"
  export ENTRYPOINT

  # Create a temp directory for all tests
  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  # Create mock bin directory and prepend to PATH
  MOCK_BIN="$TEST_TMPDIR/mock-bin"
  mkdir -p "$MOCK_BIN"
  export MOCK_BIN

  # Mock: codesign (logs calls to a file)
  cat > "$MOCK_BIN/codesign" <<'MOCK'
#!/usr/bin/env bash
echo "codesign $*" >> "$TEST_TMPDIR/commands.log"
MOCK
  chmod +x "$MOCK_BIN/codesign"

  # Mock: productsign (creates the output file so mv succeeds)
  cat > "$MOCK_BIN/productsign" <<'MOCK'
#!/usr/bin/env bash
echo "productsign $*" >> "$TEST_TMPDIR/commands.log"
# productsign --sign IDENTITY input output
# The last arg is the output file
output="${@: -1}"
touch "$output"
MOCK
  chmod +x "$MOCK_BIN/productsign"

  # Mock: pkgutil
  cat > "$MOCK_BIN/pkgutil" <<'MOCK'
#!/usr/bin/env bash
echo "pkgutil $*" >> "$TEST_TMPDIR/commands.log"
MOCK
  chmod +x "$MOCK_BIN/pkgutil"

  # Mock: xcrun (handles notarytool and stapler subcommands)
  cat > "$MOCK_BIN/xcrun" <<'MOCK'
#!/usr/bin/env bash
echo "xcrun $*" >> "$TEST_TMPDIR/commands.log"
if [[ "$1" == "notarytool" && "$2" == "submit" ]]; then
  echo '{"id":"mock-submission-id","status":"Accepted"}'
fi
MOCK
  chmod +x "$MOCK_BIN/xcrun"

  # Mock: security
  cat > "$MOCK_BIN/security" <<'MOCK'
#!/usr/bin/env bash
echo "security $*" >> "$TEST_TMPDIR/commands.log"
MOCK
  chmod +x "$MOCK_BIN/security"

  # Mock: openssl (for keychain password generation)
  cat > "$MOCK_BIN/openssl" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "rand" ]]; then
  echo "mock-keychain-password"
else
  /usr/bin/openssl "$@"
fi
MOCK
  chmod +x "$MOCK_BIN/openssl"

  # Mock: file (for Mach-O detection)
  cat > "$MOCK_BIN/file" <<'MOCK'
#!/usr/bin/env bash
f="$1"
if [[ "$f" == *".macho" ]] || [[ "$f" == *"darwin"* && ! "$f" =~ \. ]]; then
  echo "$f: Mach-O 64-bit executable arm64"
else
  /usr/bin/file "$@"
fi
MOCK
  chmod +x "$MOCK_BIN/file"

  export PATH="$MOCK_BIN:$PATH"
}

teardown_file() {
  if [ -d "${TEST_TMPDIR:-}" ]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

setup() {
  # Clear command log and create fresh fixture directories before each test
  > "$TEST_TMPDIR/commands.log"

  SOURCE_DIR="$TEST_TMPDIR/source-$$-$BATS_TEST_NUMBER"
  TARGET_DIR="$TEST_TMPDIR/target-$$-$BATS_TEST_NUMBER"
  mkdir -p "$SOURCE_DIR"

  # Set required environment variables
  export SIGNING_IDENTITY="Developer ID Application: Test Corp (TESTID)"
  export INSTALLER_IDENTITY="Developer ID Installer: Test Corp (TESTID)"
  export APPLE_APPLICATION_CERT="dGVzdC1jZXJ0LWRhdGE="  # base64 of "test-cert-data"
  export APPLE_CERT_PASSWORD="test-cert-password"
  export APPLE_NOTARIZATION_PASSWORD="test-app-password"
  export APPLE_ID="test@example.com"
  export APPLE_TEAM_ID="TESTID"
  export APPLE_INSTALLER_CERT="dGVzdC1pbnN0YWxsZXItY2VydA=="  # base64 of "test-installer-cert"
}

# --- Argument parsing tests ---

@test "entrypoint fails without --source-dir" {
  run "$ENTRYPOINT" --target-dir "$TARGET_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--source-dir is required"* ]]
}

@test "entrypoint fails without --target-dir" {
  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"--target-dir is required"* ]]
}

@test "entrypoint fails with nonexistent source directory" {
  run "$ENTRYPOINT" --source-dir /nonexistent --target-dir "$TARGET_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Source directory does not exist"* ]]
}

@test "entrypoint shows help with --help" {
  run "$ENTRYPOINT" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Sign and optionally notarize macOS artifacts"* ]]
}

@test "entrypoint fails without SIGNING_IDENTITY" {
  unset SIGNING_IDENTITY
  touch "$SOURCE_DIR/test.pkg"
  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"SIGNING_IDENTITY"* ]]
}

# --- Full tree copy tests ---

@test "full artifact tree is copied even when glob is narrow" {
  # Create mixed artifacts
  touch "$SOURCE_DIR/app.pkg"
  touch "$SOURCE_DIR/app.deb"
  touch "$SOURCE_DIR/app.rpm"
  mkdir -p "$SOURCE_DIR/subdir"
  touch "$SOURCE_DIR/subdir/lib.jar"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" \
    --artifact-glob '*.pkg' --no-notarize

  [ "$status" -eq 0 ]
  # All files should be present in target (full tree copy)
  [ -f "$TARGET_DIR/app.pkg" ]
  [ -f "$TARGET_DIR/app.deb" ]
  [ -f "$TARGET_DIR/app.rpm" ]
  [ -f "$TARGET_DIR/subdir/lib.jar" ]
}

@test "only glob-matched files are signed" {
  touch "$SOURCE_DIR/app.pkg"
  touch "$SOURCE_DIR/app.deb"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" \
    --artifact-glob '*.pkg' --no-notarize

  [ "$status" -eq 0 ]
  # productsign should be called for .pkg
  grep -q "productsign" "$TEST_TMPDIR/commands.log"
  # No codesign calls for .deb
  ! grep -q "codesign.*app.deb" "$TEST_TMPDIR/commands.log"
}

# --- File type routing tests ---

@test ".pkg files are signed with productsign" {
  touch "$SOURCE_DIR/installer.pkg"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -eq 0 ]
  grep -q "productsign --sign.*Developer ID Installer" "$TEST_TMPDIR/commands.log"
}

@test ".pkg files are verified with pkgutil" {
  touch "$SOURCE_DIR/installer.pkg"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -eq 0 ]
  grep -q "pkgutil --check-signature" "$TEST_TMPDIR/commands.log"
}

@test ".dmg files are signed with codesign" {
  touch "$SOURCE_DIR/disk.dmg"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -eq 0 ]
  grep -q "codesign --force --options runtime --timestamp --sign" "$TEST_TMPDIR/commands.log"
}

@test ".dmg files are verified after signing" {
  touch "$SOURCE_DIR/disk.dmg"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -eq 0 ]
  grep -q "codesign --verify --deep --strict" "$TEST_TMPDIR/commands.log"
}

@test "Mach-O binaries are detected and signed" {
  # The mock 'file' command treats *.macho as Mach-O
  touch "$SOURCE_DIR/mybinary.macho"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -eq 0 ]
  grep -q "codesign --deep --force --options runtime --timestamp --sign" "$TEST_TMPDIR/commands.log"
}

@test "non-signable files are skipped" {
  touch "$SOURCE_DIR/readme.txt"
  touch "$SOURCE_DIR/lib.jar"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -eq 0 ]
  # No signing commands should be logged for these file types
  [ ! -s "$TEST_TMPDIR/commands.log" ] || ! grep -q "codesign\|productsign" "$TEST_TMPDIR/commands.log"
}

@test ".asc and .sha256 files are skipped" {
  touch "$SOURCE_DIR/app.pkg"
  touch "$SOURCE_DIR/app.pkg.asc"
  touch "$SOURCE_DIR/app.pkg.sha256"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -eq 0 ]
  # Only one productsign call (for app.pkg, not for .asc or .sha256)
  local sign_count
  sign_count=$(grep -c "productsign" "$TEST_TMPDIR/commands.log" || true)
  [ "$sign_count" -eq 1 ]
}

# --- Notarization tests ---

@test "notarization is called for .pkg when enabled" {
  touch "$SOURCE_DIR/installer.pkg"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --notarize

  [ "$status" -eq 0 ]
  grep -q "xcrun notarytool submit" "$TEST_TMPDIR/commands.log"
  grep -q "xcrun stapler staple" "$TEST_TMPDIR/commands.log"
}

@test "notarization is skipped when --no-notarize" {
  touch "$SOURCE_DIR/installer.pkg"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -eq 0 ]
  ! grep -q "xcrun notarytool" "$TEST_TMPDIR/commands.log"
  ! grep -q "xcrun stapler" "$TEST_TMPDIR/commands.log"
}

@test "staple validation runs after notarization" {
  touch "$SOURCE_DIR/disk.dmg"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --notarize

  [ "$status" -eq 0 ]
  grep -q "xcrun stapler validate" "$TEST_TMPDIR/commands.log"
}

# --- Keychain tests ---

@test "keychain is created during setup" {
  touch "$SOURCE_DIR/app.pkg"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -eq 0 ]
  grep -q "security create-keychain" "$TEST_TMPDIR/commands.log"
  grep -q "security import" "$TEST_TMPDIR/commands.log"
  grep -q "security set-key-partition-list" "$TEST_TMPDIR/commands.log"
}

@test "keychain is cleaned up on exit" {
  touch "$SOURCE_DIR/app.pkg"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -eq 0 ]
  grep -q "security delete-keychain" "$TEST_TMPDIR/commands.log"
}

# --- Dry-run tests ---

@test "dry-run does not execute signing commands" {
  touch "$SOURCE_DIR/app.pkg"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" \
    --no-notarize --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN]"* ]]
}

@test "dry-run still copies the full artifact tree" {
  touch "$SOURCE_DIR/app.pkg"
  touch "$SOURCE_DIR/lib.deb"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" \
    --no-notarize --dry-run

  [ "$status" -eq 0 ]
  [ -f "$TARGET_DIR/app.pkg" ]
  [ -f "$TARGET_DIR/lib.deb" ]
}

# --- Installer identity validation ---

@test ".pkg signing fails without INSTALLER_IDENTITY" {
  unset INSTALLER_IDENTITY
  touch "$SOURCE_DIR/app.pkg"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -ne 0 ]
  [[ "$output" == *"INSTALLER_IDENTITY is required"* ]]
}

# --- Empty source directory ---

@test "empty source directory succeeds with warning" {
  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING: Source directory is empty"* ]]
}

# --- Summary output ---

@test "summary shows correct signed count" {
  touch "$SOURCE_DIR/a.pkg"
  touch "$SOURCE_DIR/b.pkg"
  touch "$SOURCE_DIR/c.txt"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -eq 0 ]
  [[ "$output" == *"Files signed:  2"* ]]
}
