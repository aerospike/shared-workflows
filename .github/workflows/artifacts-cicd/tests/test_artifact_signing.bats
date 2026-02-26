#!/usr/bin/env bats
# Test artifact signing verification
# Validates that artifacts are properly signed and signature files exist

setup() {
  # ARTIFACTS_DIR is set by the workflow
  if [ -z "$ARTIFACTS_DIR" ]; then
    echo "ERROR: ARTIFACTS_DIR environment variable not set" >&2
    exit 1
  fi
  
  if [ ! -d "$ARTIFACTS_DIR" ]; then
    echo "ERROR: Artifacts directory does not exist: $ARTIFACTS_DIR" >&2
    exit 1
  fi
}

@test "All DEB packages have corresponding .asc signature files" {
  local unsigned_debs=""
  
  while IFS= read -r deb; do
    local sig_file="${deb}.asc"
    if [ ! -f "$sig_file" ]; then
      unsigned_debs="$unsigned_debs\n  Missing signature: $(basename "$deb")"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.deb")
  
  if [ -n "$unsigned_debs" ]; then
    echo "Found unsigned DEB packages:"
    echo -e "$unsigned_debs"
    return 1
  fi
  
  return 0
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
  
  return 0
}

@test "Signature files are valid PGP signatures" {
  local invalid_sigs=""
  
  while IFS= read -r sig; do
    # Check if file contains PGP signature markers
    if ! grep -q "BEGIN PGP SIGNATURE" "$sig"; then
      invalid_sigs="$invalid_sigs\n  Invalid signature: $(basename "$sig")"
    fi
  done < <(find "$ARTIFACTS_DIR" -name "*.asc")
  
  if [ -n "$invalid_sigs" ]; then
    echo "Found invalid signature files:"
    echo -e "$invalid_sigs"
    return 1
  fi
  
  return 0
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
  
  return 0
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
  
  return 0
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
  
  return 0
}

@test "All signed artifacts from matrix are present" {
  # Should have artifacts from both jammy and el9
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
}
