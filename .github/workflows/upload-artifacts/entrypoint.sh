#!/usr/bin/env bash
set -euo pipefail

ARTIFACTS_GLOB="${1:-}"
PROJECT="${2:-}"
VERSION="${3:-}"
DRY_RUN="${4:-false}"

# Source the package utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/package_utils.sh"

upload_deb_packages() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN: Would upload DEB packages to JFrog..."
  else
    echo "Uploading DEB packages to JFrog..."
  fi

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

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  DRY RUN: Would upload $deb to $PROJECT-deb-dev-local"
      echo "  DRY RUN:   --build-name=$PROJECT-deb"
      echo "  DRY RUN:   --build-number=$VERSION"
      echo "  DRY RUN:   --target-props deb.distribution=$codename;deb.component=main;deb.architecture=$arch"
      echo "  DRY RUN:   --deb $codename/main/$arch"
    else
      # Upload the DEB
      jf rt upload "$deb" "$PROJECT-deb-dev-local" --flat=false \
        --build-name="$PROJECT-deb" \
        --build-number="$VERSION" \
        --project="$PROJECT" \
        --target-props "deb.distribution=$codename;deb.component=main;deb.architecture=$arch" \
        --deb "$codename/main/$arch"
    fi

    # Upload signature and checksum if they exist
    if [[ -f "$deb.asc" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "  DRY RUN: Would upload signature: $deb.asc"
      else
        echo "  Uploading signature: $deb.asc"
        jf rt upload "$deb.asc" "$PROJECT-deb-dev-local" --flat=false \
          --build-name="$PROJECT-deb" \
          --build-number="$VERSION" \
          --project="$PROJECT"
      fi
    fi

    if [[ -f "$deb.sha256" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "  DRY RUN: Would upload checksum: $deb.sha256"
      else
        echo "  Uploading checksum: $deb.sha256"
        jf rt upload "$deb.sha256" "$PROJECT-deb-dev-local" --flat=false \
          --build-name="$PROJECT-deb" \
          --build-number="$VERSION" \
          --project="$PROJECT"
      fi
    fi

    if [[ -f "$deb.asc.sha256" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "  DRY RUN: Would upload signature checksum: $deb.asc.sha256"
      else
        echo "  Uploading signature checksum: $deb.asc.sha256"
        jf rt upload "$deb.asc.sha256" "$PROJECT-deb-dev-local" --flat=false \
          --build-name="$PROJECT-deb" \
          --build-number="$VERSION" \
          --project="$PROJECT"
      fi
    fi
  done
}

publish_deb_build_info() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN: Would publish DEB build info..."
    echo "DRY RUN:   jf rt build-collect-env $PROJECT-deb $VERSION --project=$PROJECT"
    echo "DRY RUN:   jf rt build-add-git $PROJECT-deb $VERSION --project=$PROJECT"
    echo "DRY RUN:   jf rt build-add-dependencies $PROJECT-deb $VERSION . --project=$PROJECT"
    echo "DRY RUN:   jf rt build-publish $PROJECT-deb $VERSION --project=$PROJECT"
  else
    echo "Publishing DEB build info..."
    jf rt build-collect-env "$PROJECT-deb" "$VERSION" --project="$PROJECT"
    jf rt build-add-git "$PROJECT-deb" "$VERSION" --project="$PROJECT"
    jf rt build-add-dependencies "$PROJECT-deb" "$VERSION" . --project="$PROJECT"
    jf rt build-publish "$PROJECT-deb" "$VERSION" --project="$PROJECT"
  fi
}

upload_rpm_packages() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN: Would upload RPM packages to JFrog..."
  else
    echo "Uploading RPM packages to JFrog..."
  fi

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

    if [[ "$DRY_RUN" == "true" ]]; then
      echo "  DRY RUN: Would upload $rpm to $PROJECT-rpm-dev-local"
      echo "  DRY RUN:   --build-name=$PROJECT-rpm"
      echo "  DRY RUN:   --build-number=$VERSION"
      echo "  DRY RUN:   --target-props rpm.distribution=$dist;rpm.component=main;rpm.architecture=$arch"
    else
      # Upload the RPM
      jf rt upload "$rpm" "$PROJECT-rpm-dev-local" --flat=false \
        --build-name="$PROJECT-rpm" \
        --build-number="$VERSION" \
        --project="$PROJECT" \
        --target-props "rpm.distribution=$dist;rpm.component=main;rpm.architecture=$arch"
    fi

    # Upload signature and checksums if they exist
    if [[ -f "$rpm.asc" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "  DRY RUN: Would upload signature: $rpm.asc"
      else
        echo "  Uploading signature: $rpm.asc"
        jf rt upload "$rpm.asc" "$PROJECT-rpm-dev-local" --flat=false \
          --build-name="$PROJECT-rpm" \
          --build-number="$VERSION" \
          --project="$PROJECT"
      fi
    fi

    if [[ -f "$rpm.sha256" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "  DRY RUN: Would upload checksum: $rpm.sha256"
      else
        echo "  Uploading checksum: $rpm.sha256"
        jf rt upload "$rpm.sha256" "$PROJECT-rpm-dev-local" --flat=false \
          --build-name="$PROJECT-rpm" \
          --build-number="$VERSION" \
          --project="$PROJECT"
      fi
    fi

    if [[ -f "$rpm.asc.sha256" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "  DRY RUN: Would upload signature checksum: $rpm.asc.sha256"
      else
        echo "  Uploading signature checksum: $rpm.asc.sha256"
        jf rt upload "$rpm.asc.sha256" "$PROJECT-rpm-dev-local" --flat=false \
          --build-name="$PROJECT-rpm" \
          --build-number="$VERSION" \
          --project="$PROJECT"
      fi
    fi
  done
}

publish_rpm_build_info() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN: Would publish RPM build info..."
    echo "DRY RUN:   jf rt build-collect-env $PROJECT-rpm $VERSION --project=$PROJECT"
    echo "DRY RUN:   jf rt build-add-git $PROJECT-rpm $VERSION --project=$PROJECT"
    echo "DRY RUN:   jf rt build-add-dependencies $PROJECT-rpm $VERSION . --project=$PROJECT"
    echo "DRY RUN:   jf rt build-publish $PROJECT-rpm $VERSION --project=$PROJECT"
  else
    echo "Publishing RPM build info..."
    jf rt build-collect-env "$PROJECT-rpm" "$VERSION" --project="$PROJECT"
    jf rt build-add-git "$PROJECT-rpm" "$VERSION" --project="$PROJECT"
    jf rt build-add-dependencies "$PROJECT-rpm" "$VERSION" . --project="$PROJECT"
    jf rt build-publish "$PROJECT-rpm" "$VERSION" --project="$PROJECT"
  fi
}

upload_generic_files() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN: Would upload generic files..."
  else
    echo "Uploading generic files..."
  fi

  while IFS= read -r -d '' file; do
    if [[ -f "$file" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        echo "DRY RUN: Would upload generic file: $file"
        echo "DRY RUN:   to $PROJECT-generic-dev-local"
        echo "DRY RUN:   --build-name=$PROJECT-generic"
        echo "DRY RUN:   --build-number=$VERSION"
      else
        echo "Uploading generic file: $file"
        jf rt upload "$file" "$PROJECT-generic-dev-local" --flat=false \
          --build-name="$PROJECT-generic" \
          --build-number="$VERSION" \
          --project="$PROJECT"
      fi
    fi
  done < <(find . -type f \( -not -name "*.deb" -not -name "*.rpm" -not -name "*.asc" -not -name "*.sha256" \) -print0)
}

publish_generic_build_info() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN: Would publish generic build info..."
    echo "DRY RUN:   jf rt build-collect-env $PROJECT-generic $VERSION --project=$PROJECT"
    echo "DRY RUN:   jf rt build-add-git $PROJECT-generic $VERSION --project=$PROJECT"
    echo "DRY RUN:   jf rt build-add-dependencies $PROJECT-generic $VERSION . --project=$PROJECT"
    echo "DRY RUN:   jf rt build-publish $PROJECT-generic $VERSION --project=$PROJECT"
  else
    echo "Publishing generic build info..."
    jf rt build-collect-env "$PROJECT-generic" "$VERSION" --project="$PROJECT"
    jf rt build-add-git "$PROJECT-generic" "$VERSION" --project="$PROJECT"
    jf rt build-add-dependencies "$PROJECT-generic" "$VERSION" . --project="$PROJECT"
    jf rt build-publish "$PROJECT-generic" "$VERSION" --project="$PROJECT"
  fi
}

main() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN: Would upload artifacts to JFrog Artifactory"
  else
    echo "Uploading artifacts to JFrog Artifactory"
  fi
  echo "Artifacts glob: $ARTIFACTS_GLOB"
  echo "Project: $PROJECT"
  echo "Version: $VERSION"
  echo "Dry run: $DRY_RUN"

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

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "DRY RUN: Upload simulation complete!"
    echo "DRY RUN: Would create build names: $PROJECT-deb, $PROJECT-rpm, $PROJECT-generic"
    echo "DRY RUN: Would use build version: $VERSION"
  else
    echo "Upload complete!"
    echo "Build names: $PROJECT-deb, $PROJECT-rpm, $PROJECT-generic"
    echo "Build version: $VERSION"
  fi
}

main "$@"
