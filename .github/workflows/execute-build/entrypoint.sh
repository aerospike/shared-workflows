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
BUILD_NAME=""
BUILD_ID=""
PROJECT=""
PUBLISH_BUILD_INFO="false"

show_help() {
  echo "Usage: $0 --artifact-directory <dir> (--build-script <commands> | --build-script-path <file>) [OPTIONS]" >&2
  echo "" >&2
  echo "Set up and build using an arbitrary build script and upload the results to be used later by other actions" >&2
  echo "" >&2
  echo "Required Arguments:" >&2
  echo "  --artifact-directory <dir>     Directory that will contain all artifacts from this build" >&2
  echo "" >&2
  echo "Build Script (choose one):" >&2
  echo "  --build-script <commands>      Inline bash commands to execute" >&2
  echo "  --build-script-path <file>     Path to build script file to execute" >&2
  echo "" >&2
  echo "Options:" >&2
  echo "  --build-name <name>            Build name for JFrog build-info" >&2
  echo "  --build-id <id>                 Build ID for JFrog build-info" >&2
  echo "  --project <project>            JFrog project for build-info" >&2
  echo "  --publish-build-info           Publish build-info to JFrog (without uploading artifacts)" >&2
  echo "  --dry-run                      Show what would be done without actually doing it" >&2
  echo "  --help, -h                     Show this help message" >&2
  echo "" >&2
  echo "Examples:" >&2
  echo "  $0 --build-script-path ./scripts/build.sh --artifact-directory build-output --build-name my-app --build-id 123" >&2
  echo "  $0 --build-script 'make all && cp build/* artifacts/' --artifact-directory artifacts --build-name my-app --build-id 123" >&2
  echo "  $0 --build-script-path make.sh --artifact-directory artifacts --dry-run" >&2
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --build-script)
      if [[ -n "${BUILD_SCRIPT:-}" ]]; then
        error "Cannot specify both --build-script and --build-script-path"
      fi
      BUILD_SCRIPT="$2"
      BUILD_SCRIPT_TYPE="inline"
      shift 2
      ;;
    --build-script-path)
      if [[ -n "${BUILD_SCRIPT:-}" ]]; then
        error "Cannot specify both --build-script and --build-script-path"
      fi
      BUILD_SCRIPT="$2"
      BUILD_SCRIPT_TYPE="file"
      shift 2
      ;;
    --artifact-directory)
      ARTIFACT_DIRECTORY="$2"
      shift 2
      ;;
    --build-name)
      BUILD_NAME="$2"
      shift 2
      ;;
    --build-id)
      BUILD_ID="$2"
      shift 2
      ;;
    --project)
      PROJECT="$2"
      shift 2
      ;;
    --publish-build-info)
      PUBLISH_BUILD_INFO="true"
      shift
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
if [[ -z "${BUILD_SCRIPT:-}" ]]; then
  error "Either --build-script or --build-script-path is required. Use --help for usage information"
fi

if [[ -z "${ARTIFACT_DIRECTORY:-}" ]]; then
  error "--artifact-directory is required. Use --help for usage information"
fi

# Validate build-info parameters if publishing
if [[ "$PUBLISH_BUILD_INFO" == "true" ]]; then
  if [[ -z "${BUILD_NAME:-}" ]]; then
    error "--build-name is required when --publish-build-info is specified"
  fi
  if [[ -z "${BUILD_ID:-}" ]]; then
    error "--build-id is required when --publish-build-info is specified"
  fi
  if [[ -z "${PROJECT:-}" ]]; then
    error "--project is required when --publish-build-info is specified"
  fi
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
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Would execute build-artifacts workflow" >&2
  else
    echo "Executing build-artifacts workflow" >&2
  fi
  
  echo "Build script type: $BUILD_SCRIPT_TYPE" >&2
  echo "Build script: $BUILD_SCRIPT" >&2
  echo "Artifact directory: $ARTIFACT_DIRECTORY" >&2
  echo "Build name: $BUILD_NAME" >&2
  echo "Build ID: $BUILD_ID" >&2
  echo "Dry run: $DRY_RUN" >&2
  
  # Handle build script based on type
  local resolved_build_script

  if [[ "$BUILD_SCRIPT_TYPE" == "inline" ]]; then
    local temp_script="/tmp/build-script-$$.sh"
    echo "#!/bin/bash" > "$temp_script"
    echo "set -euo pipefail" >> "$temp_script"
    echo "$BUILD_SCRIPT" >> "$temp_script"
    chmod +x "$temp_script"
    echo "temp_script: $temp_script"
    resolved_build_script="$temp_script"
    
    echo "Created temporary script from inline commands: $temp_script" >&2
  else
    # File path - resolve to absolute path
    if [[ "$BUILD_SCRIPT" = /* ]]; then
      resolved_build_script="$BUILD_SCRIPT"
    else
      resolved_build_script="$(realpath "$BUILD_SCRIPT")"
    fi
  fi

  echo "Resolved build script path: $resolved_build_script" >&2

  if [[ ! -f "$resolved_build_script" ]]; then
    error "Build script not found: $BUILD_SCRIPT (resolved to: $resolved_build_script)"
  fi
  
  run chmod +x "$resolved_build_script"
  run mkdir -p "$ARTIFACT_DIRECTORY"
  run "$resolved_build_script"
  
  # Verify artifacts were created
  if [[ "$DRY_RUN" == "false" ]]; then
    if [[ ! -d "$ARTIFACT_DIRECTORY" ]] || [[ -z "$(ls -A "$ARTIFACT_DIRECTORY" 2>/dev/null)" ]]; then
      error "No artifacts found in $ARTIFACT_DIRECTORY after build completed"
    fi
    find "$ARTIFACT_DIRECTORY" -type f 
  else
    echo "   Would verify artifacts in: $ARTIFACT_DIRECTORY" >&2
  fi
  
  # Collect and publish build-info if requested
  if [[ "$PUBLISH_BUILD_INFO" == "true" ]]; then
    echo "Collecting build-info for $BUILD_NAME/$BUILD_ID..." >&2
    echo "Publishing from working directory: $(pwd)" >&2
    
    run_optional jf rt build-collect-env "$BUILD_NAME" "$BUILD_ID" --project="$PROJECT"
    run_optional jf rt build-add-git "$BUILD_NAME" "$BUILD_ID" --project="$PROJECT"
    run jf rt build-publish "$BUILD_NAME" "$BUILD_ID" --project="$PROJECT"
    
    echo "Published build-info: $BUILD_NAME/$BUILD_ID" >&2
  fi
  
  echo "Build-artifacts workflow completed successfully!" >&2

}

main "$@" 
