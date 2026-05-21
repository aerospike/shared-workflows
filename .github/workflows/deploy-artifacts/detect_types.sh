#!/usr/bin/env bash
# Standalone helper: run content-based type detection and structuring only
# (structure_content_detected_files). Only needs the merged artifacts tree.

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

BUILD_ARTIFACTS_DIR="build-artifacts"
WORKING_DIR=""

usage() {
    cat >&2 <<'EOF'
Usage:
  detect_types.sh [OPTIONS]

Runs content-based artifact detection (npm / PyPI / Go / Helm on ambiguous archives; NuGet
.nupkg/.snupkg by extension after .nuspec validation; plus wheel / Maven / Docker passes) and
copies matches into ./structured_build_artifacts/, with a .manifest file like the deploy entrypoint.

Options:
  --artifacts-dir <path>   Input tree root to scan (default: build-artifacts).
                           Must match paths returned by find (same as BUILD_ARTIFACTS_DIR).
  --working-dir <path>     cd here before reading artifacts / writing output
  --help, -h               This help

Environment:
  BUILD_ARTIFACTS_DIR      Same as --artifacts-dir if set before invocation
EOF
}

echo "Command line: $0 $*" >&2

while [[ $# -gt 0 ]]; do
    case $1 in
    --artifacts-dir)
        BUILD_ARTIFACTS_DIR="$2"
        shift 2
        ;;
    --working-dir)
        WORKING_DIR="$2"
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
        echo "Unexpected argument: $1" >&2
        usage
        exit 1
        ;;
    esac
done

export BUILD_ARTIFACTS_DIR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -n $WORKING_DIR ]]; then
    cd "$WORKING_DIR" || error "cannot cd to --working-dir: $WORKING_DIR"
fi
[[ -d $BUILD_ARTIFACTS_DIR ]] || error "artifacts directory not found: $BUILD_ARTIFACTS_DIR (cwd: $(pwd))"

# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/helm-helpers.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/package_utils.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/type_registry.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/upload_utils.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/type_detection.sh"

echo "Content-based type detection (artifacts root: $BUILD_ARTIFACTS_DIR)..." >&2
mkdir -p structured_build_artifacts
# This step is running in a separate workflow step, so we need to flush the manifest
init_manifest flush
for dir in "${TYPE_STRUCT_DIR[@]}"; do
    mkdir -p "structured_build_artifacts/$dir"
done
structure_content_detected_files
echo "Done. Structured tree: $(pwd)/structured_build_artifacts" >&2
