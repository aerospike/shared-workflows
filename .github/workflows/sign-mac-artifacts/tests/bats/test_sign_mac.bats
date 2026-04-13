#!/usr/bin/env bats
# Tests for sign-mac-artifacts entrypoint.sh
#
# These tests mock Apple signing tools (codesign, productsign, xcrun, security, pkgutil)
# since they are only available on macOS and require real certificates.
# Tests validate argument parsing, file type routing, glob filtering, keychain lifecycle,
# pkg content codesigning, notarization status checking, and staple retry.

setup_file() {
  GIT_ROOT="$(git rev-parse --show-toplevel)"
  export GIT_ROOT
  ENTRYPOINT="$GIT_ROOT/.github/workflows/sign-mac-artifacts/entrypoint.sh"
  export ENTRYPOINT

  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  MOCK_BIN="$TEST_TMPDIR/mock-bin"
  mkdir -p "$MOCK_BIN"
  export MOCK_BIN

  # Mock: codesign
  # --verify succeeds by default (for post-sign verification).
  # Tests that need --verify to fail (simulating unsigned pkg contents)
  # create $TEST_TMPDIR/codesign_verify_fail.
  cat > "$MOCK_BIN/codesign" <<'MOCK'
#!/usr/bin/env bash
echo "codesign $*" >> "$TEST_TMPDIR/commands.log"
if [[ "$1" == "--verify" ]]; then
  if [[ -f "$TEST_TMPDIR/codesign_verify_fail" ]]; then
    exit 1
  fi
  exit 0
fi
MOCK
  chmod +x "$MOCK_BIN/codesign"

  # Mock: productsign (creates the output file so mv succeeds)
  cat > "$MOCK_BIN/productsign" <<'MOCK'
#!/usr/bin/env bash
echo "productsign $*" >> "$TEST_TMPDIR/commands.log"
output="${@: -1}"
touch "$output"
MOCK
  chmod +x "$MOCK_BIN/productsign"

  # Mock: pkgutil (handles --expand, --flatten, and --check-signature)
  cat > "$MOCK_BIN/pkgutil" <<'MOCK'
#!/usr/bin/env bash
echo "pkgutil $*" >> "$TEST_TMPDIR/commands.log"
if [[ "$1" == "--expand" ]]; then
  expanded_dir="$3"
  mkdir -p "$expanded_dir/test.pkg"
  # Create a tar.gz Payload with a mock binary (tar works on both Linux and macOS)
  payload_tmp=$(mktemp -d)
  mkdir -p "$payload_tmp/usr/local/bin"
  echo "mock-binary-content" > "$payload_tmp/usr/local/bin/testapp"
  tar -czf "$expanded_dir/test.pkg/Payload" -C "$payload_tmp" .
  rm -rf "$payload_tmp"
elif [[ "$1" == "--flatten" ]]; then
  output="$3"
  touch "$output"
fi
MOCK
  chmod +x "$MOCK_BIN/pkgutil"

  # Mock: xcrun (handles notarytool and stapler)
  cat > "$MOCK_BIN/xcrun" <<'MOCK'
#!/usr/bin/env bash
echo "xcrun $*" >> "$TEST_TMPDIR/commands.log"
if [[ "$1" == "notarytool" && "$2" == "submit" ]]; then
  # Check for override file to return non-Accepted status
  if [[ -f "$TEST_TMPDIR/notary_status_override" ]]; then
    cat "$TEST_TMPDIR/notary_status_override"
  else
    echo '{"id":"mock-submission-id","status":"Accepted"}'
  fi
elif [[ "$1" == "notarytool" && "$2" == "log" ]]; then
  echo '{"status":"Invalid","statusSummary":"Mock rejection"}'
elif [[ "$1" == "stapler" && "$2" == "staple" ]]; then
  # Check for override file to simulate staple failures
  if [[ -f "$TEST_TMPDIR/staple_fail_count" ]]; then
    count=$(cat "$TEST_TMPDIR/staple_fail_count")
    if [[ $count -gt 0 ]]; then
      echo "$(( count - 1 ))" > "$TEST_TMPDIR/staple_fail_count"
      echo "The staple and validate action failed! Error 65." >&2
      exit 1
    fi
  fi
fi
MOCK
  chmod +x "$MOCK_BIN/xcrun"

  # Mock: security
  cat > "$MOCK_BIN/security" <<'MOCK'
#!/usr/bin/env bash
echo "security $*" >> "$TEST_TMPDIR/commands.log"
MOCK
  chmod +x "$MOCK_BIN/security"

  # Mock: openssl (handles rand for keychain password and pkcs12 for cert import)
  cat > "$MOCK_BIN/openssl" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "rand" ]]; then
  echo "mock-keychain-password"
elif [[ "$1" == "pkcs12" ]]; then
  echo "openssl $*" >> "$TEST_TMPDIR/commands.log"
  # Extract the -out argument and write fake PEM content
  out_file=""
  for i in $(seq 1 $#); do
    if [[ "${!i}" == "-out" ]]; then
      next=$((i + 1))
      out_file="${!next}"
      break
    fi
  done
  if [[ -n "$out_file" ]]; then
    if [[ "$*" == *"-clcerts"* ]]; then
      echo "-----BEGIN CERTIFICATE-----
bW9jay1jZXJ0LWRhdGE=
-----END CERTIFICATE-----" > "$out_file"
    elif [[ "$*" == *"-nocerts"* ]]; then
      echo "-----BEGIN PRIVATE KEY-----
bW9jay1rZXktZGF0YQ==
-----END PRIVATE KEY-----" > "$out_file"
    fi
  fi
else
  /usr/bin/openssl "$@"
fi
MOCK
  chmod +x "$MOCK_BIN/openssl"

  # Mock: file (for Mach-O detection)
  cat > "$MOCK_BIN/file" <<'MOCK'
#!/usr/bin/env bash
f="$1"
if [[ "$f" == *".macho" ]] || [[ "$f" == *"darwin"* && ! "$f" =~ \. ]] || [[ "$f" == *"testapp"* ]]; then
  echo "$f: Mach-O 64-bit executable arm64"
else
  /usr/bin/file "$@"
fi
MOCK
  chmod +x "$MOCK_BIN/file"

  # Mock: python3 (for notarization JSON parsing)
  cat > "$MOCK_BIN/python3" <<'MOCK'
#!/usr/bin/env bash
/usr/bin/python3 "$@"
MOCK
  chmod +x "$MOCK_BIN/python3"

  # Mock: base64 (handles -d for decoding fake cert data)
  cat > "$MOCK_BIN/base64" <<'MOCK'
#!/usr/bin/env bash
if [[ "$1" == "-d" ]]; then
  # Read stdin and write mock binary data
  cat > /dev/null
  echo -n "mock-p12-binary-data"
else
  /usr/bin/base64 "$@"
fi
MOCK
  chmod +x "$MOCK_BIN/base64"

  # Mock: cpio (passthrough for pkg repackaging)
  cat > "$MOCK_BIN/cpio" <<'MOCK'
#!/usr/bin/env bash
echo "cpio $*" >> "$TEST_TMPDIR/commands.log"
# Just consume stdin and produce minimal output
cat > /dev/null
MOCK
  chmod +x "$MOCK_BIN/cpio"

  export PATH="$MOCK_BIN:$PATH"
}

teardown_file() {
  if [ -d "${TEST_TMPDIR:-}" ]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

setup() {
  > "$TEST_TMPDIR/commands.log"
  rm -f "$TEST_TMPDIR/codesign_verify_fail"
  rm -f "$TEST_TMPDIR/notary_status_override"
  rm -f "$TEST_TMPDIR/staple_fail_count"

  SOURCE_DIR="$TEST_TMPDIR/source-$$-$BATS_TEST_NUMBER"
  TARGET_DIR="$TEST_TMPDIR/target-$$-$BATS_TEST_NUMBER"
  mkdir -p "$SOURCE_DIR"

  export SIGNING_IDENTITY="Developer ID Application: Test Corp (TESTID)"
  export INSTALLER_IDENTITY="Developer ID Installer: Test Corp (TESTID)"
  export APPLE_APPLICATION_CERT="dGVzdC1jZXJ0LWRhdGE="
  export APPLE_CERT_PASSWORD="test-cert-password"
  export APPLE_NOTARIZATION_PASSWORD="test-app-password"
  export APPLE_ID="test@example.com"
  export APPLE_TEAM_ID="TESTID"
  export APPLE_INSTALLER_CERT="dGVzdC1pbnN0YWxsZXItY2VydA=="
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
  touch "$SOURCE_DIR/app.pkg"
  touch "$SOURCE_DIR/app.deb"
  touch "$SOURCE_DIR/app.rpm"
  mkdir -p "$SOURCE_DIR/subdir"
  touch "$SOURCE_DIR/subdir/lib.jar"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" \
    --artifact-glob '*.pkg' --no-notarize

  [ "$status" -eq 0 ]
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
  grep -q "productsign" "$TEST_TMPDIR/commands.log"
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
  ! grep -q "codesign.*--sign" "$TEST_TMPDIR/commands.log"
  ! grep -q "productsign" "$TEST_TMPDIR/commands.log"
}

@test ".asc and .sha256 files are skipped" {
  touch "$SOURCE_DIR/app.pkg"
  touch "$SOURCE_DIR/app.pkg.asc"
  touch "$SOURCE_DIR/app.pkg.sha256"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -eq 0 ]
  local sign_count
  sign_count=$(grep -c "productsign" "$TEST_TMPDIR/commands.log" || true)
  [ "$sign_count" -eq 1 ]
}

# --- Pkg contents codesigning tests ---

@test "unsigned binaries inside .pkg are codesigned before productsign" {
  touch "$SOURCE_DIR/installer.pkg"
  # Make codesign --verify fail so binaries appear unsigned
  touch "$TEST_TMPDIR/codesign_verify_fail"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -eq 0 ]
  [[ "$output" == *"Expanding .pkg to codesign embedded binaries"* ]]
  [[ "$output" == *"Codesigning:"* ]]
  local codesign_line productsign_line
  codesign_line=$(grep -n "codesign --deep --force" "$TEST_TMPDIR/commands.log" | head -1 | cut -d: -f1)
  productsign_line=$(grep -n "productsign" "$TEST_TMPDIR/commands.log" | head -1 | cut -d: -f1)
  [ "$codesign_line" -lt "$productsign_line" ]
}

@test "already-signed binaries inside .pkg are skipped" {
  touch "$SOURCE_DIR/installer.pkg"
  # codesign --verify succeeds by default, so binaries appear already signed

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -eq 0 ]
  [[ "$output" == *"Already signed, skipping"* ]]
  ! grep -q "codesign --deep --force" "$TEST_TMPDIR/commands.log"
}

# --- Notarization tests ---

@test "notarization is called for .pkg when enabled" {
  touch "$SOURCE_DIR/installer.pkg"
  export STAPLE_RETRY_DELAY=0

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
  export STAPLE_RETRY_DELAY=0

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --notarize

  [ "$status" -eq 0 ]
  grep -q "xcrun stapler validate" "$TEST_TMPDIR/commands.log"
}

@test "notarization rejects non-Accepted status" {
  touch "$SOURCE_DIR/installer.pkg"
  echo '{"id":"mock-id","status":"Invalid"}' > "$TEST_TMPDIR/notary_status_override"
  export STAPLE_RETRY_DELAY=0

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --notarize

  [ "$status" -ne 0 ]
  [[ "$output" == *"was not accepted"* ]]
  [[ "$output" == *"status=Invalid"* ]]
}

@test "staple retries on transient failure then succeeds" {
  touch "$SOURCE_DIR/installer.pkg"
  echo "2" > "$TEST_TMPDIR/staple_fail_count"
  export STAPLE_RETRY_DELAY=0

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --notarize

  [ "$status" -eq 0 ]
  [[ "$output" == *"Staple attempt 1/6 failed"* ]]
  [[ "$output" == *"Staple attempt 2/6 failed"* ]]
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

@test "PEM import chain calls openssl pkcs12 and security import" {
  touch "$SOURCE_DIR/app.pkg"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --no-notarize

  [ "$status" -eq 0 ]
  # openssl pkcs12 called to extract cert and key PEM
  grep -q "openssl pkcs12.*-clcerts.*-nokeys" "$TEST_TMPDIR/commands.log"
  grep -q "openssl pkcs12.*-nocerts.*-nodes" "$TEST_TMPDIR/commands.log"
  # security import called for cert and key PEM files
  local import_count
  import_count=$(grep -c "security import" "$TEST_TMPDIR/commands.log" || true)
  # 2 certs (application + installer) x 2 files each (cert PEM + key PEM) = 4
  [ "$import_count" -eq 4 ]
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
