#!/usr/bin/env bats
# Test artifact signing verification
# Validates that artifacts are properly signed and signature files exist
#
# Two modes:
#   CI:    ARTIFACTS_DIR is pre-set to pipeline-signed output (deb + rpm)
#   Local: Imports the repo's fake GPG key, runs the sign-artifacts entrypoint
#          against .rpm fixtures, and validates the output

setup_file() {
  GIT_ROOT="$(git rev-parse --show-toplevel)"
  TESTS_DIR="$GIT_ROOT/.github/workflows/artifacts-cicd/tests"
  ENTRYPOINT="$GIT_ROOT/.github/workflows/sign-artifacts/entrypoint.sh"

  # CI mode — caller already provides signed artifacts
  if [ -n "${ARTIFACTS_DIR:-}" ]; then
    export LOCAL_SIGNING=false
    return
  fi

  export LOCAL_SIGNING=true

  # Create unsigned fixtures
  "$TESTS_DIR/create-test-fixtures.sh"

  # Load fake secrets (same keys CI uses)
  # shellcheck source=fakesecrets.env
  source "$GIT_ROOT/fakesecrets.env"

  # Set up temp GNUPGHOME with the repo's fake GPG key
  SIGN_TMPDIR="$(mktemp -d)"
  export SIGN_TMPDIR
  export GNUPGHOME="$SIGN_TMPDIR/gnupg"
  mkdir -p "$GNUPGHOME"
  chmod 700 "$GNUPGHOME"

  echo "$GPG_PASS" > "$GNUPGHOME/passphrase"
  chmod 600 "$GNUPGHOME/passphrase"

  # Configure GPG for non-interactive use
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

  # Import the fake GPG key pair
  gpg --batch --import <<< "$GPG_SECRET_KEY"
  gpg --batch --import <<< "$GPG_PUBLIC_KEY"

  # Restart gpg-agent with new config
  gpgconf --kill gpg-agent 2>/dev/null || true

  # Get key fingerprint for rpm macros
  local key_fp
  key_fp=$(gpg --list-secret-keys --with-colons | awk -F: '/^fpr:/ { print $10 }' | head -n1)
  local gpg_bin
  gpg_bin=$(command -v gpg)

  # Configure rpm macros (mirrors setup-gpg action)
  cat > "$SIGN_TMPDIR/.rpmmacros" <<MACROS
%_signature gpg
%_gpg_path $GNUPGHOME
%_gpg_name $key_fp
%_gpgbin $gpg_bin
%__gpg $gpg_bin
%__gpg_sign_cmd %{__gpg} --batch --pinentry-mode loopback --passphrase-file $GNUPGHOME/passphrase --no-armor --no-secmem-warning --no-tty -u "%{_gpg_name}" -sbo %{__signature_filename} %{__plaintext_filename}
MACROS

  # Run the actual sign-artifacts entrypoint with HOME pointed at our temp dir
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
  # Clean up generated fixtures
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

@test "All DEB packages have corresponding .asc signature files" {
  local count=0
  local unsigned_debs=""

  while IFS= read -r deb; do
    count=$((count + 1))
    local sig_file="${deb}.asc"
    if [ ! -f "$sig_file" ]; then
      unsigned_debs="$unsigned_debs\n  Missing signature: $(basename "$deb")"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.deb")

  # Skip when running locally with no .deb fixtures
  if [ "$count" -eq 0 ] && [ "${LOCAL_SIGNING:-}" = "true" ]; then
    skip "No .deb fixtures (dpkg-sig not available locally)"
  fi

  if [ -n "$unsigned_debs" ]; then
    echo "Found unsigned DEB packages:"
    echo -e "$unsigned_debs"
    return 1
  fi
}

@test "All RPM packages have corresponding .asc signature files" {
  local unsigned_rpms=""

  while IFS= read -r rpm; do
    local sig_file="${rpm}.asc"
    if [ ! -f "$sig_file" ]; then
      unsigned_rpms="$unsigned_rpms\n  Missing signature: $(basename "$rpm")"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.rpm")

  if [ -n "$unsigned_rpms" ]; then
    echo "Found unsigned RPM packages:"
    echo -e "$unsigned_rpms"
    return 1
  fi
}

@test "Signature files are valid GPG signatures" {
  local invalid_sigs=""

  while IFS= read -r sig; do
    # gpg --list-packets validates both binary and ASCII-armored signatures
    if ! gpg --list-packets "$sig" 2>/dev/null | grep -q "signature packet"; then
      invalid_sigs="$invalid_sigs\n  Invalid signature: $(basename "$sig")"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.asc")

  if [ -n "$invalid_sigs" ]; then
    echo "Found invalid signature files:"
    echo -e "$invalid_sigs"
    return 1
  fi
}

@test "All signature files are non-empty" {
  local empty_sigs=""

  while IFS= read -r sig; do
    if [ ! -s "$sig" ]; then
      empty_sigs="$empty_sigs\n  Empty signature: $(basename "$sig")"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.asc")

  if [ -n "$empty_sigs" ]; then
    echo "Found empty signature files:"
    echo -e "$empty_sigs"
    return 1
  fi
}

@test "Signature count matches artifact count" {
  local artifact_count
  artifact_count=$(find "$ARTIFACTS_DIR" \( -name "*.deb" -o -name "*.rpm" \) | wc -l)

  local sig_count
  sig_count=$(find "$ARTIFACTS_DIR" -name "*.asc" | wc -l)

  echo "Artifacts: $artifact_count, Signatures: $sig_count"

  [ "$artifact_count" -eq "$sig_count" ]
}

@test "No orphaned signature files exist" {
  # Every .asc file should have a corresponding package
  local orphaned_sigs=""

  while IFS= read -r sig; do
    local package_file="${sig%.asc}"
    if [ ! -f "$package_file" ]; then
      orphaned_sigs="$orphaned_sigs\n  Orphaned signature: $(basename "$sig")"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.asc")

  if [ -n "$orphaned_sigs" ]; then
    echo "Found orphaned signature files:"
    echo -e "$orphaned_sigs"
    return 1
  fi
}

@test "Signed artifacts maintain correct naming" {
  # After signing, original naming should be preserved
  local naming_issues=""

  # Check DEBs
  while IFS= read -r deb; do
    local basename
    basename=$(basename "$deb")
    if ! echo "$basename" | grep -qE '^hi_[0-9]+\.[0-9]+\.[0-9]+-test_(ubuntu|debian)[^_]+_x86_64\.deb$'; then
      naming_issues="$naming_issues\n  Invalid DEB name: $basename"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.deb")

  # Check RPMs
  while IFS= read -r rpm; do
    local basename
    basename=$(basename "$rpm")
    if ! echo "$basename" | grep -qE '^hi-[0-9]+\.[0-9]+\.[0-9]+-test-[0-9]+\.(el|amzn)[^.]+\.x86_64\.rpm$'; then
      naming_issues="$naming_issues\n  Invalid RPM name: $basename"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.rpm")

  if [ -n "$naming_issues" ]; then
    echo "Found naming issues in signed artifacts:"
    echo -e "$naming_issues"
    return 1
  fi
}

@test "All signed artifacts from matrix are present" {
  # In CI: should have artifacts from both jammy (deb) and el9 (rpm)
  # Locally: only .rpm fixtures are available
  if [ "${LOCAL_SIGNING:-}" = "true" ]; then
    # Verify we have at least the expected local fixtures
    local found_el9=0
    local found_amzn=0

    find "$ARTIFACTS_DIR" -name "*el9*.rpm" | grep -q . && found_el9=1
    find "$ARTIFACTS_DIR" -name "*amzn*.rpm" | grep -q . && found_amzn=1

    echo "Found EL9 (signed): $found_el9, Amazon Linux (signed): $found_amzn"

    [ "$found_el9" -eq 1 ]
    [ "$found_amzn" -eq 1 ]
  else
    local found_jammy=0
    local found_el9=0

    if find "$ARTIFACTS_DIR" -name "*ubuntu22.04*.deb" -o -name "*jammy*.deb" | grep -q .; then
      found_jammy=1
    fi

    if find "$ARTIFACTS_DIR" -name "*el9*.rpm" | grep -q .; then
      found_el9=1
    fi

    echo "Found Jammy (signed): $found_jammy, EL9 (signed): $found_el9"

    [ "$found_jammy" -eq 1 ]
    [ "$found_el9" -eq 1 ]
  fi
}
