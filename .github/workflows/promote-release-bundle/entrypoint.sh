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
    echo "::error::${1-}"
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
RECORDS=""
BUNDLE_PATHS=""
MISSING=""

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
    echo "A stage counts only when completed promotions to it hold every artifact of the version." >&2
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

# Sets MISSING to the number of the version's artifacts that no completed promotion to the stage
# holds, or to "" when the version has no completed promotion to it.
count_missing_at() {
    local stage="$1" ids id held="" paths
    MISSING=""
    ids=$(jfrog_completed_promotion_ids "$RECORDS" "$stage") ||
        error "unexpected promotion records for ${BUNDLE_NAME}/${VERSION}"
    [[ -n $ids ]] || return 0
    if [[ -z $BUNDLE_PATHS ]]; then
        BUNDLE_PATHS=$(jfrog_bundle_artifact_paths "$BUNDLE_NAME" "$VERSION" "$PROJECT") ||
            error "cannot promote without the artifact list of ${BUNDLE_NAME}/${VERSION}"
    fi
    for id in $ids; do
        paths=$(jfrog_promotion_artifact_paths "$BUNDLE_NAME" "$VERSION" "$PROJECT" "$id") ||
            error "cannot read the ${stage} promotion ${id} of ${BUNDLE_NAME}/${VERSION}"
        held+="${paths}"$'\n'
    done
    MISSING=$(LC_ALL=C comm -23 <(printf '%s\n' "$BUNDLE_PATHS") <(printf '%s' "$held" | LC_ALL=C sort -u) | grep -c . || true)
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
    local required
    required=$(stage_requires "$TARGET_STAGE") ||
        error "unknown target stage: ${TARGET_STAGE}. Expected DEV, TEST, STAGE, PREVIEW, INTERNAL or PROD"

    RECORDS=$(jfrog_promotion_records "$BUNDLE_NAME" "$VERSION" "$PROJECT") ||
        error "cannot promote without the promotion records for ${BUNDLE_NAME}/${VERSION}"

    count_missing_at "$TARGET_STAGE"
    if [[ $MISSING == 0 ]]; then
        echo "${BUNDLE_NAME}/${VERSION} is already promoted to ${TARGET_STAGE}. Nothing to do." >&2
        exit 0
    fi
    if [[ -n $required ]]; then
        count_missing_at "$required"
        if [[ -z $MISSING ]]; then
            error "${BUNDLE_NAME}/${VERSION} is not promoted to ${required}, so it cannot be promoted to ${TARGET_STAGE}"
        elif [[ $MISSING != 0 ]]; then
            error "${MISSING} artifacts of ${BUNDLE_NAME}/${VERSION} are not promoted to ${required}, so it cannot be promoted to ${TARGET_STAGE}"
        fi
    fi

    promote
    if [[ $DRY_RUN == "true" ]]; then
        echo "Would promote ${BUNDLE_NAME}/${VERSION} to ${TARGET_STAGE}" >&2
    else
        echo "Promoted ${BUNDLE_NAME}/${VERSION} to ${TARGET_STAGE}" >&2
    fi
}

main "$@"
