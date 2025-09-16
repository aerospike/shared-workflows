#!/usr/bin/env bash
set -euo pipefail

export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
trap 'handle_error ${LINENO}' ERR
# shellcheck disable=SC2317
handle_error() {
    local exit_code=$?
    local line_number=$1
    echo "Error: Command failed with exit code $exit_code at line $line_number" >&2
    exit 1
}
error() {
    local reason="${1:-}"
    if [[ -n "$reason" ]]; then
        echo "Error: $reason" >&2
    else
        echo "Error" >&2
    fi
    exit 1
}

# Default values
DRY_RUN="false"
# print full command line
echo "Command line: $0 $*" >&2
# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --help|-h)
      echo "Usage: $0 <project> <build-name> <version> <build-number> [OPTIONS]" >&2
      echo "" >&2
      echo "Uploads artifacts to JFrog Artifactory" >&2
      echo "" >&2
      echo "Options:" >&2
      echo "  --dry-run        Show what would be uploaded without actually uploading" >&2
      echo "  --help, -h       Show this help message" >&2
      echo "" >&2
      echo "Examples:" >&2
      echo "  $0  database my-app v1.0.0 1754566442238" >&2
      echo "  $0  database my-app v1.0.0 1754566442238 --dry-run" >&2
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Use --help for usage information" >&2
      exit 1
      ;;
    *)
      # Positional arguments
      if [[ -z "${PROJECT:-}" ]]; then
        PROJECT="$1"
      elif [[ -z "${BUILD_NAME:-}" ]]; then
        BUILD_NAME="$1"
      elif [[ -z "${VERSION:-}" ]]; then
        VERSION="$1"
      elif [[ -z "${BUILD_NUMBER:-}" ]]; then
        BUILD_NUMBER="$1"
      else
        echo "Use --help for usage information" >&2
        exit 1
      fi
      shift
      ;;
  esac
done


if [[ -z "${PROJECT:-}" ]]; then
  error "project is required
Use --help for usage information"
fi

if [[ -z "${BUILD_NAME:-}" ]]; then
  error "build-name is required
Use --help for usage information"
fi

if [[ -z "${VERSION:-}" ]]; then
  error "version is required
Use --help for usage information"
fi

if [[ -z "${BUILD_NUMBER:-}" ]]; then
  error "build-number is required
Use --help for usage information"
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

    echo -e "${green}   $*${reset}" >&2
  else
    "$@"
  fi
}

run_optional() {
    "$@" || echo "Warning: $*" >&2
}

structure_build_artifacts() {
  echo "Structuring build artifacts..." >&2
  mkdir -p structured_build_artifacts
  while IFS= read -r -d '' deb; do
    if [[ ! -f "$deb" ]]; then
      continue
    fi

    echo "Processing DEB: $deb" >&2
    process_deb "$deb" "./structured_build_artifacts"
  done < <(find build-artifacts -name "*.deb" -print0)

  while IFS= read -r -d '' rpm; do
    if [[ ! -f "$rpm" ]]; then
      continue
    fi

    echo "Processing RPM: $rpm" >&2
    process_rpm "$rpm" "./structured_build_artifacts"
  done < <(find build-artifacts -name "*.rpm" -print0)
}

upload_deb_packages() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would upload DEB packages to JFrog..." >&2
  else
    echo "Uploading DEB packages to JFrog..." >&2
  fi

  while IFS= read -r -d '' deb; do
    if [[ ! -f "$deb" ]]; then
      continue
    fi
    # Get package metadata
    pkgname=$(dpkg-deb -f "$deb" Package)
    arch=$(dpkg-deb -f "$deb" Architecture)
    if ! codename=$(get_codename_for_deb "$deb"); then
        error "Failed to get codename for $deb"
    fi

    echo "  Package: $pkgname, Arch: $arch, Codename: $codename" >&2
    # Upload the DEB

    run jf rt upload "$deb" "$PROJECT-deb-dev-local" --flat=false \
      --build-name="$BUILD_NAME" \
      --build-number="$BUILD_NUMBER" \
      --project="$PROJECT" \
      --target-props "version=$VERSION;deb.distribution=$codename;deb.component=main;deb.architecture=$arch" \
      --deb "$codename/main/$arch"

    # Upload signature and checksum if they exist
    if [[ -f "$deb.asc" ]]; then
      echo "  Uploading signature: $deb.asc" >&2
      run jf rt upload "$deb.asc" "$PROJECT-deb-dev-local" --flat=false \
        --build-name="$BUILD_NAME" \
        --build-number="$BUILD_NUMBER" \
        --project="$PROJECT"
    fi

    if [[ -f "$deb.sha256" ]]; then
      echo "  Uploading checksum: $deb.sha256" >&2
      run jf rt upload "$deb.sha256" "$PROJECT-deb-dev-local" --flat=false \
        --build-name="$BUILD_NAME" \
        --build-number="$BUILD_NUMBER" \
        --project="$PROJECT"
    fi

    if [[ -f "$deb.asc.sha256" ]]; then
      echo "  Uploading signature checksum: $deb.asc.sha256" >&2
      run jf rt upload "$deb.asc.sha256" "$PROJECT-deb-dev-local" --flat=false \
        --build-name="$BUILD_NAME" \
        --build-number="$BUILD_NUMBER" \
        --project="$PROJECT"
    fi
  done < <(find . -name "*.deb" -print0)
}

upload_rpm_packages() {
  
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would upload RPM packages to JFrog..." >&2
  else
    echo "Uploading RPM packages to JFrog..." >&2
  fi

  while IFS= read -r -d '' rpm; do
    if [[ ! -f "$rpm" ]]; then
      continue
    fi

    # Get metadata using the shared function
    read -r -a metadata < <(get_rpm_metadata "$rpm")
    pkgname="${metadata[0]}"
    version="${metadata[1]}"
    arch="${metadata[2]}"
    dist="${metadata[3]}"

    echo "  Package: $pkgname, Version: $version, Arch: $arch, Dist: $dist" >&2

    # Upload the RPM
    run jf rt upload "$rpm" "$PROJECT-rpm-dev-local" --flat=false \
      --build-name="$BUILD_NAME" \
      --build-number="$BUILD_NUMBER" \
      --project="$PROJECT" \
      --target-props "version=$VERSION;rpm.distribution=$dist;rpm.component=main;rpm.architecture=$arch"

    # Upload signature and checksums if they exist
    if [[ -f "$rpm.asc" ]]; then
      echo "  Uploading signature: $rpm.asc" >&2
      run jf rt upload "$rpm.asc" "$PROJECT-rpm-dev-local" --flat=false \
        --build-name="$BUILD_NAME" \
        --build-number="$BUILD_NUMBER" \
        --project="$PROJECT"
    fi

    if [[ -f "$rpm.sha256" ]]; then
      echo "  Uploading checksum: $rpm.sha256" >&2
      run jf rt upload "$rpm.sha256" "$PROJECT-rpm-dev-local" --flat=false \
        --build-name="$BUILD_NAME" \
        --build-number="$BUILD_NUMBER" \
        --project="$PROJECT"
    fi

    if [[ -f "$rpm.asc.sha256" ]]; then
      echo "  Uploading signature checksum: $rpm.asc.sha256" >&2
      run jf rt upload "$rpm.asc.sha256" "$PROJECT-rpm-dev-local" --flat=false \
        --build-name="$BUILD_NAME" \
        --build-number="$BUILD_NUMBER" \
        --project="$PROJECT"
    fi
  done < <(find . -name "*.rpm" -print0)
}

upload_generic_files() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would upload generic files..." >&2
  else
    echo "Uploading generic files..." >&2
  fi

  while IFS= read -r -d '' file; do
    if [[ -f "$file" ]]; then
      echo "Uploading generic file: $file" >&2
      run jf rt upload "$file" "$PROJECT-generic-dev-local" --flat=false \
        --build-name="$BUILD_NAME" \
        --build-number="$BUILD_NUMBER" \
        --project="$PROJECT"
    fi
  done < <(find . -type f \( -not -name "*.deb" -not -name "*.rpm" -not -name "*.asc" -not -name "*.sha256" \) -print0)
}

# Note for future: This helper that checks if the build exists is needed
# because this functionality is not in the jf command line. There are ways to do this with the rest API but for the specific
# purpose of checking if there is already a build with the same name and number, this looks like the cleanest solution.
check_build_exists() {
  local build_name="$1"
  local build_number="$2"
  local project="$3"
  
  local count
  count=$(jf rt search "${project}-build-info/$build_name/$build_number-*" --count 2>/dev/null | tail -n 1)
  
  if [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -gt 0 ]]; then
    return 0  # Build exists
  else
    return 1  # Build does not exist
  fi
}

publish_build_info() {
  if check_build_exists "$BUILD_NAME" "$BUILD_NUMBER" "$PROJECT"; then
    echo "Build already exists, updating build info with uploaded artifacts" >&2
    run jf rt build-update "$BUILD_NAME" "$BUILD_NUMBER" --project="$PROJECT"
  else
    echo "Publishing build info..." >&2
    run_optional jf rt build-collect-env "$BUILD_NAME" "$BUILD_NUMBER" --project="$PROJECT"
    run_optional jf rt build-add-git "$BUILD_NAME" "$BUILD_NUMBER" --project="$PROJECT"
    run jf rt build-publish "$BUILD_NAME" "$BUILD_NUMBER" --project="$PROJECT"
  fi
}

main() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would upload artifacts to JFrog Artifactory" >&2
  else
    echo "Uploading artifacts to JFrog Artifactory" >&2
  fi
  echo "Project: $PROJECT" >&2
  echo "Build name: $BUILD_NAME" >&2
  echo "Version: $VERSION" >&2
  echo "Dry run: $DRY_RUN" >&2
  echo "Build number: $BUILD_NUMBER" >&2
  mkdir -p structured_build_artifacts
  shopt -s globstar nullglob

  structure_build_artifacts
  cd structured_build_artifacts
  
  # Upload all packages
  upload_rpm_packages
  upload_deb_packages
  upload_generic_files
  # Publish build info once for the unified build
  publish_build_info

  echo "Upload complete!" >&2
  echo "Build name: $BUILD_NAME" >&2
  echo "Build number: $BUILD_NUMBER" >&2
}

main "$@"
