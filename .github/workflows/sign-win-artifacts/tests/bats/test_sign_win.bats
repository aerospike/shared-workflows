#!/usr/bin/env bats
# Tests for sign-win-artifacts entrypoint.sh
#
# Mocks CodeSignTool.sh for Linux CI. Covers argument validation, tree copy,
# glob filtering, .exe/.msi/.msix signing, and dry-run behavior.

setup_file() {
  GIT_ROOT="$(git rev-parse --show-toplevel)"
  export GIT_ROOT
  ENTRYPOINT="$GIT_ROOT/.github/workflows/sign-win-artifacts/entrypoint.sh"
  export ENTRYPOINT

  TEST_TMPDIR="$(mktemp -d)"
  export TEST_TMPDIR

  MOCK_BIN="$TEST_TMPDIR/mock-bin"
  mkdir -p "$MOCK_BIN"
  export MOCK_BIN

  cat > "$MOCK_BIN/CodeSignTool.sh" <<'MOCK'
#!/usr/bin/env bash
echo "CodeSignTool $*" >> "$TEST_TMPDIR/commands.log"
infile=""
outdir=""
for arg in "$@"; do
  case "$arg" in
  sign) ;;
  -input_file_path=*) infile="${arg#-input_file_path=}" ;;
  -output_dir_path=*) outdir="${arg#-output_dir_path=}" ;;
  esac
done
if [[ -z "$infile" || -z "$outdir" ]]; then
  echo "mock: missing input or output dir" >&2
  exit 1
fi
mkdir -p "$outdir"
cp "$infile" "$outdir/$(basename "$infile")"
MOCK
  chmod +x "$MOCK_BIN/CodeSignTool.sh"

  export PATH="$MOCK_BIN:$PATH"
}

teardown_file() {
  if [ -d "${TEST_TMPDIR:-}" ]; then
    rm -rf "$TEST_TMPDIR"
  fi
}

setup() {
  > "$TEST_TMPDIR/commands.log"

  SOURCE_DIR="$TEST_TMPDIR/source-$$-$BATS_TEST_NUMBER"
  TARGET_DIR="$TEST_TMPDIR/target-$$-$BATS_TEST_NUMBER"
  mkdir -p "$SOURCE_DIR"

  export ES_USERNAME="user@example.com"
  export ES_PASSWORD="secret-pass"
  export CREDENTIAL_ID="cred-uuid-test"
  export ES_TOTP_SECRET="totp-secret-test"
  export CODESIGNTOOL="$MOCK_BIN/CodeSignTool.sh"
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
  [[ "$output" == *"Sign Windows artifacts"* ]]
}

@test "entrypoint fails without eSigner secrets when not dry-run" {
  unset ES_USERNAME
  touch "$SOURCE_DIR/app.exe"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR"
  [ "$status" -ne 0 ]
  [[ "$output" == *"ES_USERNAME"* ]]
}

# --- Full tree copy tests ---

@test "full artifact tree is copied even when glob is narrow" {
  touch "$SOURCE_DIR/app.exe"
  touch "$SOURCE_DIR/app.deb"
  mkdir -p "$SOURCE_DIR/subdir"
  touch "$SOURCE_DIR/subdir/lib.jar"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" \
    --artifact-glob '*.exe' --dry-run

  [ "$status" -eq 0 ]
  [ -f "$TARGET_DIR/app.exe" ]
  [ -f "$TARGET_DIR/app.deb" ]
  [ -f "$TARGET_DIR/subdir/lib.jar" ]
}

@test "only glob-matched exe is signed in non-dry-run" {
  echo "fake-exe" > "$SOURCE_DIR/app.exe"
  echo "fake-deb" > "$SOURCE_DIR/app.deb"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" \
    --artifact-glob '*.exe'

  [ "$status" -eq 0 ]
  grep -q "CodeSignTool.*sign" "$TEST_TMPDIR/commands.log"
  ! grep -q "app.deb" "$TEST_TMPDIR/commands.log"
  [[ "$(cat "$TARGET_DIR/app.exe")" == "fake-exe" ]]
}

@test "comma-separated artifact-glob signs multiple Windows types" {
  echo "fake-exe" > "$SOURCE_DIR/app.exe"
  echo "fake-msi" > "$SOURCE_DIR/setup.msi"
  echo "fake-msix" > "$SOURCE_DIR/bundle.msix"
  echo "fake-deb" > "$SOURCE_DIR/app.deb"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" \
    --artifact-glob '*.exe, *.msi, *.msix'

  [ "$status" -eq 0 ]
  grep -q "app.exe" "$TEST_TMPDIR/commands.log"
  grep -q "setup.msi" "$TEST_TMPDIR/commands.log"
  grep -q "bundle.msix" "$TEST_TMPDIR/commands.log"
  ! grep -q "app.deb" "$TEST_TMPDIR/commands.log"
}

@test ".exe is signed with CodeSignTool" {
  echo "payload" > "$SOURCE_DIR/tool.exe"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR"

  [ "$status" -eq 0 ]
  grep -q "CodeSignTool.*sign.*-input_file_path=.*tool.exe" "$TEST_TMPDIR/commands.log"
}

@test ".msi is signed with CodeSignTool" {
  echo "msi-payload" > "$SOURCE_DIR/setup.msi"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR"

  [ "$status" -eq 0 ]
  grep -q "CodeSignTool.*sign.*-input_file_path=.*setup.msi" "$TEST_TMPDIR/commands.log"
}

@test ".msi receives -program_name when ESIGNER_PROGRAM_NAME is set" {
  echo "msi" > "$SOURCE_DIR/setup.msi"
  export ESIGNER_PROGRAM_NAME="Contoso Setup"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR"

  [ "$status" -eq 0 ]
  grep -q -- "-program_name=Contoso Setup" "$TEST_TMPDIR/commands.log"
}

@test ".exe does not receive -program_name when ESIGNER_PROGRAM_NAME is set" {
  echo "bin" > "$SOURCE_DIR/app.exe"
  export ESIGNER_PROGRAM_NAME="Contoso Setup"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR"

  [ "$status" -eq 0 ]
  ! grep -q "program_name" "$TEST_TMPDIR/commands.log"
}

@test ".msix is signed with CodeSignTool" {
  echo "msix-payload" > "$SOURCE_DIR/bundle.msix"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR"

  [ "$status" -eq 0 ]
  grep -q "CodeSignTool.*sign.*-input_file_path=.*bundle.msix" "$TEST_TMPDIR/commands.log"
  [[ "$(cat "$TARGET_DIR/bundle.msix")" == "msix-payload" ]]
}

@test ".msix dry-run invokes redacted CodeSignTool line" {
  echo "x" > "$SOURCE_DIR/pkg.msix"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"Processing .msix"* ]]
  [[ "$output" == *"[DRY-RUN]"* ]]
  [[ "$output" == *"pkg.msix"* ]]
}

@test "non-signable files are skipped" {
  touch "$SOURCE_DIR/readme.txt"
  touch "$SOURCE_DIR/lib.jar"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --dry-run

  [ "$status" -eq 0 ]
  ! grep -q "CodeSignTool" "$TEST_TMPDIR/commands.log"
}

@test "dry-run does not require eSigner secrets" {
  unset ES_USERNAME ES_PASSWORD CREDENTIAL_ID ES_TOTP_SECRET
  echo "x" > "$SOURCE_DIR/a.exe"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"[DRY-RUN]"* ]]
}

@test "dry-run output redacts credentials" {
  echo "x" > "$SOURCE_DIR/a.exe"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR" --dry-run

  [ "$status" -eq 0 ]
  [[ "$output" == *"-password=***"* ]]
  [[ "$output" != *"secret-pass"* ]]
}

@test "uppercase extension .EXE is signed" {
  echo "data" > "$SOURCE_DIR/TOOL.EXE"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR"

  [ "$status" -eq 0 ]
  grep -q "TOOL.EXE" "$TEST_TMPDIR/commands.log"
}

@test ".asc files are ignored for signing" {
  echo "sig" > "$SOURCE_DIR/file.asc"
  echo "exe" > "$SOURCE_DIR/file.exe"

  run "$ENTRYPOINT" --source-dir "$SOURCE_DIR" --target-dir "$TARGET_DIR"

  [ "$status" -eq 0 ]
  grep -q "file.exe" "$TEST_TMPDIR/commands.log"
  ! grep -q "file.asc" "$TEST_TMPDIR/commands.log"
}
