#!/usr/bin/env bash
set -euo pipefail

ARTIFACTS_GLOB="${1:-}"
PROJECT="${2:-}"
VERSION="${3:-}"

# Source the package utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/package_utils.sh"

upload_deb_packages() {
  echo "Uploading DEB packages to JFrog..."
  
  find . -name "*.deb" -print0 | while IFS= read -r -d '' deb; do
    if [[ ! -f "$deb" ]]; then
      continue
    fi
    
    echo "Processing DEB: $deb"
    
    # Get package metadata
    pkgname=$(dpkg-deb -f "$deb" Package)
    arch=$(dpkg-deb -f "$deb" Architecture)
    codename=$(get_codename_for_deb "$deb")
    
    echo "  Package: $pkgname, Arch: $arch, Codename: $codename"
    
    # Upload the DEB
    jf rt upload "$deb" "$PROJECT-deb-dev-local" --flat=false \
      --build-name="$PROJECT-deb" \
      --build-number="$VERSION" \
      --project="$PROJECT" \
      --target-props "deb.distribution=$codename;deb.component=main;deb.architecture=$arch" \
      --deb "$codename/main/$arch"
    
    # Upload signature and checksum if they exist
    if [[ -f "$deb.asc" ]]; then
      echo "  Uploading signature: $deb.asc"
      jf rt upload "$deb.asc" "$PROJECT-deb-dev-local" --flat=false \
        --build-name="$PROJECT-deb" \
        --build-number="$VERSION" \
        --project="$PROJECT"
    fi
    
    if [[ -f "$deb.sha256" ]]; then
      echo "  Uploading checksum: $deb.sha256"
      jf rt upload "$deb.sha256" "$PROJECT-deb-dev-local" --flat=false \
        --build-name="$PROJECT-deb" \
        --build-number="$VERSION" \
        --project="$PROJECT"
    fi
    
    if [[ -f "$deb.asc.sha256" ]]; then
      echo "  Uploading signature checksum: $deb.asc.sha256"
      jf rt upload "$deb.asc.sha256" "$PROJECT-deb-dev-local" --flat=false \
        --build-name="$PROJECT-deb" \
        --build-number="$VERSION" \
        --project="$PROJECT"
    fi
  done
}

publish_deb_build_info() {
  echo "Publishing DEB build info..."
  jf rt build-collect-env "$PROJECT-deb" "$VERSION" --project="$PROJECT"
  jf rt build-add-git "$PROJECT-deb" "$VERSION" --project="$PROJECT"
  jf rt build-add-dependencies "$PROJECT-deb" "$VERSION" . --project="$PROJECT"
  jf rt build-publish "$PROJECT-deb" "$VERSION" --project="$PROJECT"
}

upload_rpm_packages() {
  echo "Uploading RPM packages to JFrog..."
  
  find . -name "*.rpm" -print0 | while IFS= read -r -d '' rpm; do
    if [[ ! -f "$rpm" ]]; then
      continue
    fi
    
    echo "Processing RPM: $rpm"
    
    # Get metadata using the shared function
    read -r -a metadata < <(get_rpm_metadata "$rpm")
    pkgname="${metadata[0]}"
    version="${metadata[1]}"
    arch="${metadata[2]}"
    dist="${metadata[3]}"
    
    echo "  Package: $pkgname, Version: $version, Arch: $arch, Dist: $dist"
    
    # Upload the RPM
    jf rt upload "$rpm" "$PROJECT-rpm-dev-local" --flat=false \
      --build-name="$PROJECT-rpm" \
      --build-number="$VERSION" \
      --project="$PROJECT" \
      --target-props "rpm.distribution=$dist;rpm.component=main;rpm.architecture=$arch"
    
    # Upload signature and checksums if they exist
    if [[ -f "$rpm.asc" ]]; then
      echo "  Uploading signature: $rpm.asc"
      jf rt upload "$rpm.asc" "$PROJECT-rpm-dev-local" --flat=false \
        --build-name="$PROJECT-rpm" \
        --build-number="$VERSION" \
        --project="$PROJECT"
    fi
    
    if [[ -f "$rpm.sha256" ]]; then
      echo "  Uploading checksum: $rpm.sha256"
      jf rt upload "$rpm.sha256" "$PROJECT-rpm-dev-local" --flat=false \
        --build-name="$PROJECT-rpm" \
        --build-number="$VERSION" \
        --project="$PROJECT"
    fi
    
    if [[ -f "$rpm.asc.sha256" ]]; then
      echo "  Uploading signature checksum: $rpm.asc.sha256"
      jf rt upload "$rpm.asc.sha256" "$PROJECT-rpm-dev-local" --flat=false \
        --build-name="$PROJECT-rpm" \
        --build-number="$VERSION" \
        --project="$PROJECT"
    fi
  done
}

publish_rpm_build_info() {
  echo "Publishing RPM build info..."
  jf rt build-collect-env "$PROJECT-rpm" "$VERSION" --project="$PROJECT"
  jf rt build-add-git "$PROJECT-rpm" "$VERSION" --project="$PROJECT"
  jf rt build-add-dependencies "$PROJECT-rpm" "$VERSION" . --project="$PROJECT"
  jf rt build-publish "$PROJECT-rpm" "$VERSION" --project="$PROJECT"
}

upload_generic_files() {
  echo "Uploading generic files..."
  while IFS= read -r -d '' file; do
    if [[ -f "$file" ]]; then
      echo "Uploading generic file: $file"
      jf rt upload "$file" "$PROJECT-generic-dev-local" --flat=false \
        --build-name="$PROJECT-generic" \
        --build-number="$VERSION" \
        --project="$PROJECT"
    fi
  done < <(find . -type f \( -not -name "*.deb" -not -name "*.rpm" -not -name "*.asc" -not -name "*.sha256" \) -print0)
}

publish_generic_build_info() {
  echo "Publishing generic build info..."
  jf rt build-collect-env "$PROJECT-generic" "$VERSION" --project="$PROJECT"
  jf rt build-add-git "$PROJECT-generic" "$VERSION" --project="$PROJECT"
  jf rt build-add-dependencies "$PROJECT-generic" "$VERSION" . --project="$PROJECT"
  jf rt build-publish "$PROJECT-generic" "$VERSION" --project="$PROJECT"
}

main() {
  echo "Uploading artifacts to JFrog Artifactory"                                                                         
  echo "Artifacts glob: $ARTIFACTS_GLOB"
  echo "Project: $PROJECT"
  echo "Version: $VERSION"

  # Expand glob pattern to find files in build-artifacts
  cd build-artifacts
  shopt -s globstar nullglob
  eval "FILES=( $ARTIFACTS_GLOB )"

  if [[ ${#FILES[@]} -eq 0 ]]; then
    echo "No matching artifacts found for pattern: $ARTIFACTS_GLOB"
    exit 1
  fi

  echo "Found ${#FILES[@]} artifact(s) to process"

  # Upload and publish DEB packages
  upload_deb_packages
  publish_deb_build_info

  # Upload and publish RPM packages
  upload_rpm_packages
  publish_rpm_build_info

  # Upload and publish generic files
  upload_generic_files
  publish_generic_build_info

  echo "Upload complete!"
  echo "Build names: $PROJECT-deb, $PROJECT-rpm, $PROJECT-generic"
  echo "Build version: $VERSION"
}

main "$@"
