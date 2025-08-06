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

show_help() {
  echo "Usage: $0 --project <project> --build-names <builds> --bundle-name <name> --version <version> [OPTIONS]" >&2
  echo "" >&2
  echo "Create JFrog release bundles from a configurable list of build names" >&2
  echo "" >&2
  echo "Required Arguments:" >&2
  echo "  --project <project>        JFrog Artifactory project name" >&2
  echo "  --build-names <builds>     Comma-separated list of build names to include" >&2
  echo "  --bundle-name <name>       Name for the release bundle" >&2
  echo "  --version <version>        Version of the release bundle" >&2
  echo "" >&2
  echo "Options:" >&2
  echo "  --dry-run                  Show what would be done without actually doing it" >&2
  echo "  --help, -h                 Show this help message" >&2
  echo "" >&2
  echo "Examples:" >&2
  echo "  $0 --project database --build-names 'db-build-1,db-build-2' --bundle-name database-release --version v1.0.0" >&2
  echo "  $0 --project app --build-names 'app-build' --bundle-name app-release --version v2.1.0 --dry-run" >&2
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --project)
      PROJECT="$2"
      shift 2
      ;;
    --build-names)
      BUILD_NAMES="$2"
      shift 2
      ;;
    --bundle-name)
      BUNDLE_NAME="$2"
      shift 2
      ;;
    --version)
      VERSION="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      show_help
      exit 1
      ;;
    *)
      echo "Unexpected positional argument: $1" >&2
      show_help
      exit 1
      ;;
  esac
done

# Validate required arguments
if [[ -z "${PROJECT:-}" ]]; then
   echo "--project is required."
   show_help
   exit 1
fi

if [[ -z "${BUILD_NAMES:-}" ]]; then
   echo "--build-names is required."
   show_help
   exit 1
fi

if [[ -z "${BUNDLE_NAME:-}" ]]; then
   echo "--bundle-name is required."
   show_help
   exit 1
fi

if [[ -z "${VERSION:-}" ]]; then
   echo "--version is required."
   show_help
   exit 1
fi

# Wrapper function that either executes or echoes commands
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    local green='\033[0;32m'
    local reset='\033[0m'
    echo -e "${green}   $*${reset}" >&2
  else
    "$@"
  fi
}

main() {
  echo "Command line: $0 $*" >&2
  
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would execute create-release-bundle workflow" >&2
    echo "The following JFrog commands would be executed:" >&2
    echo "" >&2
  else
    echo "Executing create-release-bundle workflow" >&2
  fi
  
  echo "Project: $PROJECT" >&2
  echo "Build names: $BUILD_NAMES" >&2
  echo "Bundle name: $BUNDLE_NAME" >&2
  echo "Version: $VERSION" >&2
  echo "Dry run: $DRY_RUN" >&2
  
  # Convert comma-separated build names to array
  IFS=',' read -ra BUILD_ARRAY <<< "$BUILD_NAMES"
  
  # Validate that builds exist
  for build_name in "${BUILD_ARRAY[@]}"; do
    build_name=$(echo "$build_name" | xargs)  # trim whitespace
    if [[ -z "$build_name" ]]; then
      continue
    fi
    
    echo "Validating build: $build_name" >&2
    if [[ "$DRY_RUN" == "true" ]]; then
      echo "   Would check if build exists: jf rt build-info $build_name" >&2
    else
      if ! jf rt build-info "$build_name" >/dev/null 2>&1; then
        error "Build not found: $build_name"
      fi
    fi
  done
  
  # Create release bundle
  echo "Creating release bundle: $BUNDLE_NAME/$VERSION" >&2
  
  # Create the release bundle spec file
  cat > release-bundle-spec.json <<EOF
{
  "name": "$BUNDLE_NAME",
  "version": "$VERSION",
  "description": "Release for build version $VERSION",
  "files": [
$(for ((i=0; i<${#BUILD_ARRAY[@]}; i++)); do
  build_name=$(echo "${BUILD_ARRAY[i]}" | xargs)
  if [[ -n "$build_name" ]]; then
    echo "    {"
    echo "      \"project\": \"$PROJECT\","
    echo "      \"build\": \"$build_name/$VERSION\""
    if [[ $i -lt $((${#BUILD_ARRAY[@]}-1)) ]]; then
      echo "    },"
    else
      echo "    }"
    fi
  fi
done)
  ]
}
EOF

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would execute: jf release-bundle-create $BUNDLE_NAME $VERSION --spec release-bundle-spec.json --project=$PROJECT --signing-key=aerospike" >&2
    echo "Spec file:" >&2
    cat release-bundle-spec.json >&2
  else
    # Create the release bundle
    run jf release-bundle-create "$BUNDLE_NAME" "$VERSION" \
      --spec release-bundle-spec.json \
      --project="$PROJECT" \
      --signing-key="aerospike"
  fi
  
  echo "Create release bundle workflow completed successfully!" >&2
}

main "$@" 
