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
      echo "  --metadata-build-number <prefix> Build ID prefix used to discover related metadata builds (searches for <prefix>*.json)" >&2
      echo "  --dry-run        Show what would be uploaded without actually uploading" >&2
      echo "  --help, -h       Show this help message" >&2
      echo "" >&2
      echo "Examples:" >&2
      echo "  $0  database my-app v1.0.0 1754566442238 1754566442238-metadata" >&2
      echo "  $0  database my-app v1.0.0 1754566442238 1754566442238-metadata --dry-run" >&2
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
      elif [[ -z "${METADATA_BUILD_NUMBER:-}" ]]; then
        METADATA_BUILD_NUMBER="$1"
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

if [[ -z "${METADATA_BUILD_NUMBER:-}" ]]; then
  error "metadata-build-number is required
Use --help for usage information"
fi
ARTIFACT_BUILD_NUMBER="$BUILD_NUMBER-artifacts"

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
    run "$@" || echo "Warning: $*" >&2
}

structure_build_artifacts() {
  echo "Structuring build artifacts..." >&2
  echo "current files: $(ls -la build-artifacts)" >&2
  mkdir -p structured_build_artifacts/deb
  mkdir -p structured_build_artifacts/rpm
  mkdir -p structured_build_artifacts/jar
  mkdir -p structured_build_artifacts/nupkg
  mkdir -p structured_build_artifacts/generic
  while IFS= read -r -d '' deb; do
    if [[ ! -f "$deb" ]]; then
      continue
    fi

    echo "Processing DEB: $deb" >&2
    process_deb "$deb" "./structured_build_artifacts/deb"
  done < <(find build-artifacts -name "*.deb" -print0)

  while IFS= read -r -d '' rpm; do
    if [[ ! -f "$rpm" ]]; then
      continue
    fi

    echo "Processing RPM: $rpm" >&2
    process_rpm "$rpm" "./structured_build_artifacts/rpm"
  done < <(find build-artifacts -name "*.rpm" -print0)
  echo "current files: $(ls -la build-artifacts)" >&2

  while IFS= read -r -d '' jar; do
    if [[ ! -f "$jar" ]]; then
      continue
    fi

    echo "Processing JAR: $jar" >&2
    process_jar "$jar" "./structured_build_artifacts/jar"
  done < <(find build-artifacts -name "*.jar" -print0)
  echo "current files: $(ls -la build-artifacts)" >&2

  while IFS= read -r -d '' nupkg; do
    if [[ ! -f "$nupkg" ]]; then
      continue
    fi

    echo "Processing JAR: $jar" >&2
    process_jar "$jar" "./structured_build_artifacts/jar"
  done < <(find build-artifacts -name "*.jar" -print0)
  echo "current files: $(ls -la build-artifacts)" >&2

  while IFS= read -r -d '' generic; do
    if [[ ! -f "$generic" ]]; then
      echo "Skipping non-file: $generic" >&2
      continue
    fi
    echo "Processing generic file: $generic" >&2
    process_generic "$generic" "./structured_build_artifacts/generic"
  done < <(find build-artifacts \( -not -name "*.deb" -not -name "*.rpm" -not -name "*.asc" -not -name "*.jar" -not -name "*.pom" \) -type f -print0)
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
      --build-number="$ARTIFACT_BUILD_NUMBER" \
      --project="$PROJECT" \
      --target-props "version=$VERSION;deb.distribution=$codename;deb.component=main;deb.architecture=$arch" \
      --deb "$codename/main/$arch"

    # Upload signature and checksum if they exist
    if [[ -f "$deb.asc" ]]; then
      echo "  Uploading signature: $deb.asc" >&2
      run jf rt upload "$deb.asc" "$PROJECT-deb-dev-local" --flat=false \
        --build-name="$BUILD_NAME" \
        --build-number="$ARTIFACT_BUILD_NUMBER" \
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
      --build-number="$ARTIFACT_BUILD_NUMBER" \
      --project="$PROJECT" \
      --target-props "version=$VERSION;rpm.distribution=$dist;rpm.component=main;rpm.architecture=$arch"

    # Upload signature and checksums if they exist
    if [[ -f "$rpm.asc" ]]; then
      echo "  Uploading signature: $rpm.asc" >&2
      run jf rt upload "$rpm.asc" "$PROJECT-rpm-dev-local" --flat=false \
        --build-name="$BUILD_NAME" \
        --build-number="$ARTIFACT_BUILD_NUMBER" \
        --project="$PROJECT"
    fi
  done < <(find . -name "*.rpm" -print0)
}

upload_jar_packages() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would upload JAR/POM packages to JFrog..." >&2
  else
    echo "Uploading JAR/POM packages to JFrog..." >&2
  fi
  
  # Find all JAR and POM files, then process unique base names
  declare -A processed_artifacts
  
  while IFS= read -r -d '' artifact; do
    if [[ ! -f "$artifact" ]]; then
      continue
    fi

    # Get the directory and base name
    artifact_dir=$(dirname "$artifact")
    artifact_name=$(basename "$artifact")
    base_name="${artifact_name%.jar}"
    base_name="${base_name%.pom}"
    
    # Skip if we've already processed this base artifact
    artifact_key="$artifact_dir/$base_name"
    if [[ -n "${processed_artifacts[$artifact_key]:-}" ]]; then
      continue
    fi
    processed_artifacts[$artifact_key]=1

    # Determine which file to use for metadata extraction (prefer POM as it's the source of truth)
    local pkgname version group_id
    
    # Fallback: Extract metadata from JAR if no POM exists
    read -r -a metadata < <(get_jar_metadata "$artifact_dir/${base_name}.jar")
    pkgname="${metadata[0]}"
    version="${metadata[1]}"
    # group might be empty if this is a simple jar file Use :- to handle empty group_id
    group_id="${metadata[2]:-}"

    echo "  Package: $pkgname, Version: $version, Group ID: $group_id" >&2

    # Upload all related Maven artifact files (jar, pom, signatures)
    for ext in jar pom jar.asc pom.asc; do
      local artifact_file="$artifact_dir/${base_name}.${ext}"
      if [[ -f "$artifact_file" ]]; then
        echo "  Uploading $ext: $artifact_file" >&2
        run jf rt upload "$artifact_file" "$PROJECT-maven-dev-local" --flat=false \
          --build-name="$BUILD_NAME" \
          --build-number="$ARTIFACT_BUILD_NUMBER" \
          --project="$PROJECT" \
          --target-props "group_id=$group_id;package_name=$pkgname;version=$version"
      fi
    done
  done < <(find . \( -name "*.jar" -o -name "*.pom" \) -print0)
}

upload_generic_files() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would upload generic files..." >&2
  else
    echo "Uploading generic files..." >&2
  fi
  echo "Finding files..." >&2
  find . >&2
  while IFS= read -r -d '' file; do
    echo "Processing generic file: $file" >&2
    if [[ -f "$file" ]]; then
      echo "Uploading generic file: $file" >&2
      run jf rt upload "$file" "$PROJECT-generic-dev-local" --flat=false \
        --build-name="$BUILD_NAME" \
        --build-number="$ARTIFACT_BUILD_NUMBER" \
        --project="$PROJECT"
    fi
  done < <(find . \( -not -name "*.deb" -not -name "*.rpm" -not -name "*.asc" -not -name "*.jar" -not -name "*.pom" \) -print0)
}


# Collects build-info metadata by querying Artifactory for JSON files.
# JFrog API doesn't support wildcarding build IDs, so we fetch the JSON
# files to extract the collection of build IDs for this parent build.
discover_build_infos() {
  local project="$1"
  local parent_build_name="$2"
  local build_info_search_pattern="$3"
  local build_info_repo="${4:-${project}-build-info}"

  echo "Discovering build-infos for project: $project" >&2
  echo "Parent build name: $parent_build_name" >&2
  echo "Search pattern: $build_info_search_pattern" >&2
  echo "Build-info repo: $build_info_repo" >&2

  read -r -d '' AQL <<AQL || true
items.find({
  "\$and":[
    {"repo":{"\$eq":"$build_info_repo"}},
    {"path":{"\$eq":"$parent_build_name"}},
    {"name":{"\$match":"$build_info_search_pattern.json"}},
    {"created":{"\$last":"1d"}}
  ]
}).include("repo","path","name")
AQL
  echo run jf rt curl -XPOST api/search/aql \
    -H 'Content-Type: text/plain' \
    -d "$AQL" >&2
  # Query for build-info JSON files
  local resp
  resp=$(run jf rt curl -XPOST api/search/aql \
    -H 'Content-Type: text/plain' \
    -d "$AQL")
  echo "search response: $resp" >&2
  # Extract child build IDs from JSON file names
  if echo "$resp" | jq -e '.results' > /dev/null 2>&1; then
    mapfile -t CHILD_BUILD_IDS < <(echo "$resp" | jq -r '.results[] | .name' | sed 's/-[0-9]*\.json$//' | sort -u)

    echo "Found ${#CHILD_BUILD_IDS[@]} child builds" >&2

    CHILD_BUILD_IDS_RESULT=("${CHILD_BUILD_IDS[@]}")
    return 0
  else
    echo "No build-info files found" >&2
    CHILD_BUILD_IDS_RESULT=()
    return 1
  fi
}


# This function handles publishing the tree of build info to jfrog
# 1. publish the signed artifacts
# 2. append metadata and artifact builld infos to new build info
# 3. publish the new build info
publish_build_info() {
    run jf rt build-publish "$BUILD_NAME" "$ARTIFACT_BUILD_NUMBER" --project="$PROJECT"

    discover_build_infos "$PROJECT" "$BUILD_NAME" "$METADATA_BUILD_NUMBER*" "$PROJECT-build-info" || true

    # Access the results
    if [[ ${#CHILD_BUILD_IDS_RESULT[@]} -gt 0 ]]; then
      echo "Found ${#CHILD_BUILD_IDS_RESULT[@]} child builds:" >&2
      for build_id in "${CHILD_BUILD_IDS_RESULT[@]}"; do
        echo "  $BUILD_NAME/$build_id"
        run jf rt build-append "$BUILD_NAME" "$BUILD_NUMBER" \
                          "$BUILD_NAME" "$build_id" --project="$PROJECT"
      done
    fi

    run jf rt build-append "$BUILD_NAME" "$BUILD_NUMBER" \
                          "$BUILD_NAME" "$ARTIFACT_BUILD_NUMBER" --project="$PROJECT"
    run jf rt build-publish "$BUILD_NAME" "$BUILD_NUMBER" --project="$PROJECT"
}

main() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would deploy artifacts to JFrog Artifactory" >&2
  else
    echo "Deploying artifacts to JFrog Artifactory" >&2
  fi
  echo "Project: $PROJECT" >&2
  echo "Build name: $BUILD_NAME" >&2
  echo "Version: $VERSION" >&2
  echo "Dry run: $DRY_RUN" >&2
  echo "Build number: $BUILD_NUMBER" >&2
  echo "Metadata build number: $METADATA_BUILD_NUMBER" >&2
  echo "current files: $(ls -la build-artifacts)" >&2
  mkdir -p structured_build_artifacts
  shopt -s globstar nullglob

  structure_build_artifacts
  cd structured_build_artifacts
  # Upload all packages
  cd rpm
  upload_rpm_packages
  cd ..
  cd deb
  upload_deb_packages
  cd ..
  cd jar
  upload_jar_packages
  cd ..
  cd generic
  upload_generic_files
  cd ..
  # Publish build info once for the unified build
  publish_build_info

  echo "Deploy complete!" >&2
  echo "Build name: $BUILD_NAME" >&2
  echo "Build number: $BUILD_NUMBER" >&2
}

main "$@"
