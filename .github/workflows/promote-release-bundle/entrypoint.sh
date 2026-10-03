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
    echo "Error: ${1-}" >&2
    exit 1
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../lib/jfrog-lifecycle.sh"

BUNDLE_NAME=""
VERSION=""
TARGET_STAGE=""
PROJECT=""
INCLUDE_REPOS=""
EXCLUDE_REPOS=""
DRY_RUN="false"

# DEV and PREVIEW are optional. Requiring DEV before TEST would lock the dev-local paths a
# rebuild of the same version deploys to.
stage_requires() {
    case "$1" in
    DEV | TEST) echo "" ;;
    STAGE) echo "TEST" ;;
    PREVIEW | INTERNAL | PROD) echo "STAGE" ;;
    *) return 1 ;;
    esac
}

show_help() {
    echo "Usage: $0 --bundle-name <name> --version <version> --target-stage <stage> --project <project> [OPTIONS]" >&2
    echo "" >&2
    echo "Promote a JFrog release bundle to a stage, refusing to skip a required stage." >&2
    echo "STAGE requires TEST; PREVIEW, INTERNAL and PROD require STAGE. DEV and PREVIEW" >&2
    echo "are optional." >&2
    echo "" >&2
    echo "Required Arguments:" >&2
    echo "  --bundle-name <name>       Release bundle name" >&2
    echo "  --version <version>        Release bundle version to promote" >&2
    echo "  --target-stage <stage>     DEV, TEST, STAGE, PREVIEW, INTERNAL or PROD" >&2
    echo "  --project <project>        JFrog project key" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --include-repos <repos>    Semicolon-separated repos to include" >&2
    echo "  --exclude-repos <repos>    Semicolon-separated repos to exclude" >&2
    echo "  --dry-run                  Print the JFrog commands without running them" >&2
    echo "  --help                     Show this help" >&2
}

run() {
    if [[ $DRY_RUN == "true" ]]; then
        echo -e "\033[0;32m   $*\033[0m" >&2
    else
        "$@"
    fi
}

promote() {
    local args=("$BUNDLE_NAME" "$VERSION" "$TARGET_STAGE" --project="$PROJECT")
    if [[ -n $INCLUDE_REPOS ]]; then
        args+=(--include-repos="$INCLUDE_REPOS")
    fi
    if [[ -n $EXCLUDE_REPOS ]]; then
        args+=(--exclude-repos="$EXCLUDE_REPOS")
    fi
    run jf release-bundle-promote "${args[@]}"
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --bundle-name)
            BUNDLE_NAME="$2"
            shift 2
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --target-stage)
            TARGET_STAGE="$2"
            shift 2
            ;;
        --project)
            PROJECT="$2"
            shift 2
            ;;
        --include-repos)
            INCLUDE_REPOS="$2"
            shift 2
            ;;
        --exclude-repos)
            EXCLUDE_REPOS="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN="true"
            shift
            ;;
        --help)
            show_help
            exit 0
            ;;
        *) error "unknown argument: $1" ;;
        esac
    done

    [[ -n $BUNDLE_NAME ]] || error "--bundle-name is required"
    [[ -n $VERSION ]] || error "--version is required"
    [[ -n $TARGET_STAGE ]] || error "--target-stage is required"
    [[ -n $PROJECT ]] || error "--project is required"
    command -v jq >/dev/null 2>&1 || error "jq is required"

    TARGET_STAGE="${TARGET_STAGE^^}"
    local required records stages
    required=$(stage_requires "$TARGET_STAGE") ||
        error "unknown target stage: ${TARGET_STAGE}. Expected DEV, TEST, STAGE, PREVIEW, INTERNAL or PROD"

    records=$(jfrog_promotion_records "$BUNDLE_NAME" "$PROJECT") ||
        error "cannot promote without the promotion records for ${BUNDLE_NAME}"
    stages=$(jfrog_promotion_stages "$records" "$VERSION")

    if grep -Fxq "$TARGET_STAGE" <<<"$stages"; then
        echo "${BUNDLE_NAME}/${VERSION} is already promoted to ${TARGET_STAGE}. Nothing to do." >&2
        exit 0
    fi
    if [[ -n $required ]] && ! grep -Fxq "$required" <<<"$stages"; then
        error "${BUNDLE_NAME}/${VERSION} is not promoted to ${required}, so it cannot be promoted to ${TARGET_STAGE}"
    fi

    promote
    echo "Promoted ${BUNDLE_NAME}/${VERSION} to ${TARGET_STAGE}" >&2
}

main "$@"
