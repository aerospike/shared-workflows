#!/usr/bin/env bash
set -euo pipefail

export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
trap 'handle_error ${LINENO}' ERR

handle_error() {
    local exit_code=$?
    local line_number=$1
    echo "Error: Command failed with exit code $exit_code at line $line_number" >&2
    exit 1
}

# Default values
DRY_RUN="false"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --help|-h)
      echo "Usage: $0 <artifacts-glob> <project> <version> [OPTIONS]"
      echo ""
      echo "Uploads artifacts to JFrog Artifactory"
      echo ""
      echo "Options:"
      echo "  --dry-run        Show what would be uploaded without actually uploading"
      echo "  --help, -h       Show this help message"
      echo ""
      echo "Examples:"
      echo "  $0 '**/*.{deb,rpm}' database v1.0.0"
      echo "  $0 '**/*.{deb,rpm}' database v1.0.0 --dry-run"
      exit 0
      ;;
    -*)
      echo "Unknown option: $1"
      echo "Use --help for usage information"
      exit 1
      ;;
    *)
      # Positional arguments
      if [[ -z "${ARTIFACTS_GLOB:-}" ]]; then
        ARTIFACTS_GLOB="$1"
      elif [[ -z "${PROJECT:-}" ]]; then
        PROJECT="$1"
      elif [[ -z "${VERSION:-}" ]]; then
        VERSION="$1"
      else
        echo "Use --help for usage information"
        exit 1
      fi
      shift
      ;;
  esac
done

# Validate required arguments
if [[ -z "${ARTIFACTS_GLOB:-}" ]]; then
  echo "Error: artifacts-glob is required"
  echo "Use --help for usage information"
  exit 1
fi

if [[ -z "${PROJECT:-}" ]]; then
  echo "Error: project is required"
  echo "Use --help for usage information"
  exit 1
fi

if [[ -z "${VERSION:-}" ]]; then
  echo "Error: version is required"
  echo "Use --help for usage information"
  exit 1
fi

# Source the package utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/package_utils.sh"

# Wrapper function that either executes or echoes commands
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    # Define color variables
    local green='\033[0;32m'
    local reset='\033[0m'

    echo -e "${green}   $*${reset}"
  else
    "$@"
  fi
}

upload_deb_packages() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would upload DEB packages to JFrog..."
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

    # Upload the DEB
    run jf rt upload "$deb" "$PROJECT-deb-dev-local" --flat=false \
      --build-name="$PROJECT-deb" \
      --build-number="$VERSION" \
      --project="$PROJECT" \
      --target-props "deb.distribution=$codename;deb.component=main;deb.architecture=$arch" \
      --deb "$codename/main/$arch"

    # Upload signature and checksum if they exist
    if [[ -f "$deb.asc" ]]; then
      echo "  Uploading signature: $deb.asc"
      run jf rt upload "$deb.asc" "$PROJECT-deb-dev-local" --flat=false \
        --build-name="$PROJECT-deb" \
        --build-number="$VERSION" \
        --project="$PROJECT"
    fi

    if [[ -f "$deb.sha256" ]]; then
      echo "  Uploading checksum: $deb.sha256"
      run jf rt upload "$deb.sha256" "$PROJECT-deb-dev-local" --flat=false \
        --build-name="$PROJECT-deb" \
        --build-number="$VERSION" \
        --project="$PROJECT"
    fi

    if [[ -f "$deb.asc.sha256" ]]; then
      echo "  Uploading signature checksum: $deb.asc.sha256"
      run jf rt upload "$deb.asc.sha256" "$PROJECT-deb-dev-local" --flat=false \
        --build-name="$PROJECT-deb" \
        --build-number="$VERSION" \
        --project="$PROJECT"
    fi
  done
}

publish_deb_build_info() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would publish DEB build info..."
  else
    echo "Publishing DEB build info..."
  fi

  run jf rt build-collect-env "$PROJECT-deb" "$VERSION" --project="$PROJECT"
  run jf rt build-add-git "$PROJECT-deb" "$VERSION" --project="$PROJECT"
  run jf rt build-add-dependencies "$PROJECT-deb" "$VERSION" . --project="$PROJECT"
  run jf rt build-publish "$PROJECT-deb" "$VERSION" --project="$PROJECT"
}

upload_rpm_packages() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would upload RPM packages to JFrog..."
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

    # Upload the RPM
    run jf rt upload "$rpm" "$PROJECT-rpm-dev-local" --flat=false \
      --build-name="$PROJECT-rpm" \
      --build-number="$VERSION" \
      --project="$PROJECT" \
      --target-props "rpm.distribution=$dist;rpm.component=main;rpm.architecture=$arch"

    # Upload signature and checksums if they exist
    if [[ -f "$rpm.asc" ]]; then
      echo "  Uploading signature: $rpm.asc"
      run jf rt upload "$rpm.asc" "$PROJECT-rpm-dev-local" --flat=false \
        --build-name="$PROJECT-rpm" \
        --build-number="$VERSION" \
        --project="$PROJECT"
    fi

    if [[ -f "$rpm.sha256" ]]; then
      echo "  Uploading checksum: $rpm.sha256"
      run jf rt upload "$rpm.sha256" "$PROJECT-rpm-dev-local" --flat=false \
        --build-name="$PROJECT-rpm" \
        --build-number="$VERSION" \
        --project="$PROJECT"
    fi

    if [[ -f "$rpm.asc.sha256" ]]; then
      echo "  Uploading signature checksum: $rpm.asc.sha256"
      run jf rt upload "$rpm.asc.sha256" "$PROJECT-rpm-dev-local" --flat=false \
        --build-name="$PROJECT-rpm" \
        --build-number="$VERSION" \
        --project="$PROJECT"
    fi
  done
}

publish_rpm_build_info() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would publish RPM build info..."
  else
    echo "Publishing RPM build info..."
  fi

  run jf rt build-collect-env "$PROJECT-rpm" "$VERSION" --project="$PROJECT"
  run jf rt build-add-git "$PROJECT-rpm" "$VERSION" --project="$PROJECT"
  run jf rt build-add-dependencies "$PROJECT-rpm" "$VERSION" . --project="$PROJECT"
  run jf rt build-publish "$PROJECT-rpm" "$VERSION" --project="$PROJECT"
}

upload_generic_files() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would upload generic files..."
  else
    echo "Uploading generic files..."
  fi

  while IFS= read -r -d '' file; do
    if [[ -f "$file" ]]; then
      echo "Uploading generic file: $file"
      run jf rt upload "$file" "$PROJECT-generic-dev-local" --flat=false \
        --build-name="$PROJECT-generic" \
        --build-number="$VERSION" \
        --project="$PROJECT"
    fi
  done < <(find . -type f \( -not -name "*.deb" -not -name "*.rpm" -not -name "*.asc" -not -name "*.sha256" \) -print0)
}

publish_generic_build_info() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would publish generic build info..."
  else
    echo "Publishing generic build info..."
  fi

  run jf rt build-collect-env "$PROJECT-generic" "$VERSION" --project="$PROJECT"
  run jf rt build-add-git "$PROJECT-generic" "$VERSION" --project="$PROJECT"
  run jf rt build-add-dependencies "$PROJECT-generic" "$VERSION" . --project="$PROJECT"
  run jf rt build-publish "$PROJECT-generic" "$VERSION" --project="$PROJECT"
}

main() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would upload artifacts to JFrog Artifactory"
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

    echo "Upload complete!"
    echo "Build names: $PROJECT-deb, $PROJECT-rpm, $PROJECT-generic"
    echo "Build version: $VERSION"
}

main "$@"
