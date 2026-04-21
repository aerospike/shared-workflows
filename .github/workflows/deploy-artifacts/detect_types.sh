#!/usr/bin/env bash
# Standalone helper: run content-based type detection and structuring only
# (structure_content_detected_files). Mirrors deploy entrypoint / workflow inputs.

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
    local reason="${1-}"
    if [[ -n $reason ]]; then
        echo "Error: $reason" >&2
    else
        echo "Error" >&2
    fi
    exit 1
}

DRY_RUN="false"
BUILD_TYPE=""
INTERNAL="false"
BUILD_ARTIFACTS_DIR="build-artifacts"
WORKING_DIR=""

usage() {
    cat >&2 <<'EOF'
Usage:
  detect_types.sh <project> <build-name> <version> <build-number> [OPTIONS]

Or set the same values with options (can mix with positionals; unfilled slots use positionals in order):

  detect_types.sh --jf-project <project> --jf-build-name <name> --version <ver> --jf-build-id <id> [OPTIONS]

Runs content-based artifact detection (npm / PyPI sdist / Go module archives under
ambiguous extensions) and copies matches into ./structured_build_artifacts/, with
a .manifest file like the deploy entrypoint.

Options (align with reusable_deploy-artifacts / entrypoint.sh):
  --jf-project, --project <name>     JFrog project (required)
  --jf-build-name, --build-name <n> Build name (required)
  --version <ver>                    Artifact version (required)
  --jf-build-id, --build-number <id> Build ID / number (required)
  --jar-group-id <group-id>          Maven group ID fallback for JAR metadata
  --build-type <label>               Target-prop build.type (e.g. release, nightly)
  --internal                         Set internal=true style metadata path (registry)
  --artifacts-dir <path>             Input tree root to scan (default: build-artifacts).
                                     Must match paths returned by find (same as BUILD_ARTIFACTS_DIR).
  --working-dir <path>               cd here before reading artifacts / writing output
  --dry-run                          Accepted for parity with entrypoint (structuring uses cp)
  --help, -h                         This help

Environment:
  BUILD_ARTIFACTS_DIR                Same as --artifacts-dir if set before invocation
EOF
}

echo "Command line: $0 $*" >&2

while [[ $# -gt 0 ]]; do
    case $1 in
    --dry-run)
        DRY_RUN="true"
        shift
        ;;
    --jar-group-id)
        JAR_GROUP_ID="$2"
        shift 2
        ;;
    --build-type)
        # shellcheck disable=SC2034
        BUILD_TYPE="$2"
        shift 2
        ;;
    --internal)
        # shellcheck disable=SC2034
        INTERNAL="true"
        shift
        ;;
    --artifacts-dir)
        BUILD_ARTIFACTS_DIR="$2"
        shift 2
        ;;
    --working-dir)
        WORKING_DIR="$2"
        shift 2
        ;;
    --jf-project | --project)
        PROJECT="$2"
        shift 2
        ;;
    --jf-build-name | --build-name)
        BUILD_NAME="$2"
        shift 2
        ;;
    --version)
        VERSION="$2"
        shift 2
        ;;
    --jf-build-id | --build-number)
        BUILD_NUMBER="$2"
        shift 2
        ;;
    --help | -h)
        usage
        exit 0
        ;;
    -*)
        echo "Unknown option: $1" >&2
        usage
        exit 1
        ;;
    *)
        if [[ -z ${PROJECT-} ]]; then
            PROJECT="$1"
        elif [[ -z ${BUILD_NAME-} ]]; then
            BUILD_NAME="$1"
        elif [[ -z ${VERSION-} ]]; then
            VERSION="$1"
        elif [[ -z ${BUILD_NUMBER-} ]]; then
            BUILD_NUMBER="$1"
        else
            echo "Unexpected argument: $1" >&2
            usage
            exit 1
        fi
        shift
        ;;
    esac
done

if [[ -z ${PROJECT-} ]]; then
    error "project is required (positional or --jf-project / --project)
Use --help for usage"
fi
if [[ -z ${BUILD_NAME-} ]]; then
    error "build-name is required (positional or --jf-build-name / --build-name)
Use --help for usage"
fi
if [[ -z ${VERSION-} ]]; then
    error "version is required (positional or --version)
Use --help for usage"
fi
if [[ -z ${BUILD_NUMBER-} ]]; then
    error "build-number is required (positional or --jf-build-id / --build-number)
Use --help for usage"
fi

export JAR_GROUP_ID
export ARTIFACT_BUILD_NUMBER="$BUILD_NUMBER-artifacts"
export BUILD_ARTIFACTS_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n $WORKING_DIR ]]; then
    cd "$WORKING_DIR" || error "cannot cd to --working-dir: $WORKING_DIR"
fi
[[ -d $BUILD_ARTIFACTS_DIR ]] || error "artifacts directory not found: $BUILD_ARTIFACTS_DIR (cwd: $(pwd))"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/package_utils.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/type_registry.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/upload_utils.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/type_detection.sh"

run() {
    if [[ $DRY_RUN == "true" ]]; then
        local green='\033[0;32m'
        local reset='\033[0m'
        echo -e "${green}   $*${reset}" >&2
    else
        "$@"
    fi
}

echo "Content-based type detection (artifacts root: $BUILD_ARTIFACTS_DIR)..." >&2
mkdir -p structured_build_artifacts
init_manifest
for dir in "${TYPE_STRUCT_DIR[@]}"; do
    mkdir -p "structured_build_artifacts/$dir"
done
structure_content_detected_files
echo "Done. Structured tree: $(pwd)/structured_build_artifacts" >&2
