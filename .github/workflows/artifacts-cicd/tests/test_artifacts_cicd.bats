#!/usr/bin/env bats
# Consolidated CI/CD artifact verification
# Validates the combined matrix output: multi-distro native, dotnet, and mac artifacts
#
# Two modes:
#   CI:    ARTIFACTS_DIR is pre-set to pipeline-signed output
#   Local: Imports the repo's fake GPG key, runs the sign-artifacts entrypoint
#          against fixture RPMs, and validates the output

setup_file() {
  GIT_ROOT="$(git rev-parse --show-toplevel)"
  TESTS_DIR="$GIT_ROOT/.github/workflows/artifacts-cicd/tests"
  ENTRYPOINT="$GIT_ROOT/.github/workflows/sign-artifacts/entrypoint.sh"

  if [ -n "${ARTIFACTS_DIR:-}" ]; then
    export LOCAL_SIGNING=false
    return
  fi

  export LOCAL_SIGNING=true

  "$TESTS_DIR/create-test-fixtures.sh"

  # shellcheck source=fakesecrets.env
  source "$GIT_ROOT/fakesecrets.env"

  SIGN_TMPDIR="$(mktemp -d)"
  export SIGN_TMPDIR
  export GNUPGHOME="$SIGN_TMPDIR/gnupg"
  mkdir -p "$GNUPGHOME"
  chmod 700 "$GNUPGHOME"

  echo "$GPG_PASS" > "$GNUPGHOME/passphrase"
  chmod 600 "$GNUPGHOME/passphrase"

  cat > "$GNUPGHOME/gpg.conf" <<CONF
use-agent
pinentry-mode loopback
batch
no-tty
passphrase-file $GNUPGHOME/passphrase
CONF
  chmod 600 "$GNUPGHOME/gpg.conf"

  cat > "$GNUPGHOME/gpg-agent.conf" <<CONF
allow-preset-passphrase
allow-loopback-pinentry
CONF
  chmod 600 "$GNUPGHOME/gpg-agent.conf"

  gpg --batch --import <<< "$GPG_SECRET_KEY"
  gpg --batch --import <<< "$GPG_PUBLIC_KEY"

  gpgconf --kill gpg-agent 2>/dev/null || true

  local key_fp
  key_fp=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ { print $10 }' | head -n1)
  local gpg_bin
  gpg_bin=$(command -v gpg)

  cat > "$SIGN_TMPDIR/.rpmmacros" <<MACROS
%_signature gpg
%_gpg_path $GNUPGHOME
%_gpg_name $key_fp
%_gpgbin $gpg_bin
%__gpg $gpg_bin
%__gpg_sign_cmd %{__gpg} --batch --pinentry-mode loopback --passphrase-file $GNUPGHOME/passphrase --no-armor --no-secmem-warning --no-tty -u "%{_gpg_name}" -sbo %{__signature_filename} %{__plaintext_filename}
MACROS

  local signed_dir="$SIGN_TMPDIR/signed"
  chmod +x "$ENTRYPOINT"
  (
    export HOME="$SIGN_TMPDIR"
    cd "$TESTS_DIR/test-artifacts" || return 1
    "$ENTRYPOINT" 'signing/**/*' "$signed_dir"
  )

  export ARTIFACTS_DIR="$signed_dir"
}

teardown_file() {
  if [ "${LOCAL_SIGNING:-}" = "true" ]; then
    gpgconf --kill gpg-agent 2>/dev/null || true
    if [ -d "${SIGN_TMPDIR:-}" ]; then
      rm -rf "$SIGN_TMPDIR"
    fi
  fi
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

# --- Multi-distro presence ---

@test "EL9 RPM artifact is present" {
  find "$ARTIFACTS_DIR" -name "*el9*.rpm" | grep -q .
}

@test "Jammy DEB artifact is present" {
  if [ "${LOCAL_SIGNING:-}" = "true" ]; then
    skip "No .deb fixtures locally"
  fi
  find "$ARTIFACTS_DIR" \( -name "*ubuntu22.04*.deb" -o -name "*jammy*.deb" \) | grep -q .
}

# --- Mixed types ---

@test "NuGet package is present" {
  if [ "${LOCAL_SIGNING:-}" = "true" ]; then
    skip "No .nupkg fixtures in local signing mode"
  fi
  find "$ARTIFACTS_DIR" -name "*.nupkg" | grep -q .
}

@test "Mac .pkg artifact is present" {
  if [ "${LOCAL_SIGNING:-}" = "true" ]; then
    skip "No .pkg fixtures locally"
  fi
  find "$ARTIFACTS_DIR" -name "*.pkg" | grep -q .
}

# --- Signing verification ---

@test "All DEB packages have corresponding .asc signature files" {
  local count=0
  local missing=""

  while IFS= read -r deb; do
    count=$((count + 1))
    if [ ! -f "${deb}.asc" ]; then
      missing="$missing\n  Missing: $(basename "$deb").asc"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.deb")

  if [ "$count" -eq 0 ] && [ "${LOCAL_SIGNING:-}" = "true" ]; then
    skip "No .deb fixtures locally"
  fi

  if [ -n "$missing" ]; then
    echo -e "Unsigned DEBs:$missing"
    return 1
  fi
}

@test "All RPM packages have corresponding .asc signature files" {
  local missing=""

  while IFS= read -r rpm_file; do
    if [ ! -f "${rpm_file}.asc" ]; then
      missing="$missing\n  Missing: $(basename "$rpm_file").asc"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.rpm")

  if [ -n "$missing" ]; then
    echo -e "Unsigned RPMs:$missing"
    return 1
  fi
}

@test "All .asc signatures are valid GPG signatures" {
  local invalid=""

  while IFS= read -r sig; do
    if ! gpg --list-packets "$sig" 2>/dev/null | grep -q "signature packet"; then
      invalid="$invalid\n  Invalid: $(basename "$sig")"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.asc")

  if [ -n "$invalid" ]; then
    echo -e "Invalid signatures:$invalid"
    return 1
  fi
}

@test "All .asc signature files are non-empty" {
  local empty=""

  while IFS= read -r sig; do
    if [ ! -s "$sig" ]; then
      empty="$empty\n  Empty: $(basename "$sig")"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.asc")

  if [ -n "$empty" ]; then
    echo -e "Empty signatures:$empty"
    return 1
  fi
}

@test "No orphaned .asc files" {
  local orphaned=""

  while IFS= read -r sig; do
    local package_file="${sig%.asc}"
    if [ ! -f "$package_file" ]; then
      orphaned="$orphaned\n  Orphaned: $(basename "$sig")"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.asc")

  if [ -n "$orphaned" ]; then
    echo -e "Orphaned signatures:$orphaned"
    return 1
  fi
}

# --- Quality checks ---

@test "All artifacts are non-empty and at least 1KB" {
  local issues=""
  local min_size=1024

  while IFS= read -r artifact; do
    local size
    size=$(stat -c%s "$artifact" 2>/dev/null || stat -f%z "$artifact" 2>/dev/null)
    if [ "$size" -lt "$min_size" ]; then
      issues="$issues\n  Too small: $(basename "$artifact") ($size bytes)"
    fi
  done < <(find "$ARTIFACTS_DIR" \( -name "*.deb" -o -name "*.rpm" -o -name "*.nupkg" -o -name "*.pkg" \))

  if [ -n "$issues" ]; then
    echo -e "Size issues:$issues"
    return 1
  fi
}

@test "No duplicate basenames across all artifacts" {
  local all_names
  all_names=$(find "$ARTIFACTS_DIR" \( -name "*.deb" -o -name "*.rpm" -o -name "*.nupkg" -o -name "*.pkg" \) -exec basename {} \; | sort)

  local duplicates
  duplicates=$(echo "$all_names" | uniq -d)

  if [ -n "$duplicates" ]; then
    echo "Duplicate artifact names:"
    echo "$duplicates"
    return 1
  fi
}
