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
    local reason="${1-}"
    if [[ -n $reason ]]; then
        echo "Error: $reason" >&2
    else
        echo "Error" >&2
    fi
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
SUPERSEDE="false"
SUPERSEDE_REASON=""
ACTOR="${GITHUB_ACTOR-unknown}"
DRY_RUN="false"

# Not a linear order: PREVIEW and INTERNAL both follow STAGE.
stage_predecessor() {
    case "$1" in
    DEV) echo "" ;;
    TEST) echo "DEV" ;;
    STAGE) echo "TEST" ;;
    PREVIEW) echo "STAGE" ;;
    INTERNAL) echo "STAGE" ;;
    PROD) echo "PREVIEW" ;;
    *) return 1 ;;
    esac
}

stage_is_frozen() {
    case "$1" in
    PREVIEW | INTERNAL | PROD) return 0 ;;
    *) return 1 ;;
    esac
}

show_help() {
    echo "Usage: $0 --bundle-name <name> --version <version> --target-stage <stage> --project <project> [OPTIONS]" >&2
    echo "" >&2
    echo "Promote a JFrog release bundle one stage forward, refusing to overwrite an" >&2
    echo "occupied stage unless a supersede is explicitly requested." >&2
    echo "" >&2
    echo "Required Arguments:" >&2
    echo "  --bundle-name <name>       Release bundle name" >&2
    echo "  --version <version>        Release bundle version to promote" >&2
    echo "  --target-stage <stage>     DEV, TEST, STAGE, PREVIEW, INTERNAL or PROD" >&2
    echo "  --project <project>        JFrog project key" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --supersede                Replace the version currently at the target stage." >&2
    echo "                             Refused for PREVIEW, INTERNAL and PROD." >&2
    echo "  --supersede-reason <text>  Why the incumbent is being replaced. Required with" >&2
    echo "                             --supersede." >&2
    echo "  --include-repos <repos>    Semicolon-separated repos to include" >&2
    echo "  --exclude-repos <repos>    Semicolon-separated repos to exclude" >&2
    echo "  --actor <name>             Who is promoting. Defaults to GITHUB_ACTOR." >&2
    echo "  --dry-run                  Print the JFrog commands without running them" >&2
    echo "  --help                     Show this help" >&2
}

run() {
    if [[ $DRY_RUN == "true" ]]; then
        local green='\033[0;32m'
        local reset='\033[0m'
        echo -e "${green}   $*${reset}" >&2
    else
        "$@"
    fi
}

# Semicolons separate properties and newlines end them, so neither can survive
# inside a value.
sanitize_property_value() {
    printf '%s' "$1" | tr ';\n\r' ',  ' | sed 's/[[:space:]]\+/ /g; s/^ //; s/ $//'
}

version_is_at_stage() {
    local records="$1" version="$2" stage="$3"
    jfrog_versions_at_stage "$records" "$stage" | grep -Fxq "$version"
}

annotate() {
    local version="$1" props="$2"
    run jf release-bundle-annotate "$BUNDLE_NAME" "$version" \
        --project="$PROJECT" \
        --properties="$props"
}

record_supersede() {
    local incumbent="$1" stamp="$2" reason="$3"

    annotate "$VERSION" \
        "supersede.replaced=${incumbent};supersede.stage=${TARGET_STAGE};supersede.at=${stamp};supersede.actor=${ACTOR};supersede.reason=${reason}"
    annotate "$incumbent" \
        "supersede.replacedBy=${VERSION};supersede.stage=${TARGET_STAGE};supersede.at=${stamp};supersede.actor=${ACTOR};supersede.reason=${reason}"

    if [[ -n ${GITHUB_STEP_SUMMARY-} ]]; then
        {
            echo "### Superseded at ${TARGET_STAGE}"
            echo ""
            echo "| Field | Value |"
            echo "| --- | --- |"
            echo "| Bundle | ${BUNDLE_NAME} |"
            echo "| Replaced | ${incumbent} |"
            echo "| Replaced by | ${VERSION} |"
            echo "| Stage | ${TARGET_STAGE} |"
            echo "| At | ${stamp} |"
            echo "| Actor | ${ACTOR} |"
            echo "| Reason | ${reason} |"
        } >>"$GITHUB_STEP_SUMMARY"
    fi
}

promote() {
    local args=("$BUNDLE_NAME" "$VERSION" "$TARGET_STAGE" --project="$PROJECT")
    [[ -n $INCLUDE_REPOS ]] && args+=(--include-repos="$INCLUDE_REPOS")
    [[ -n $EXCLUDE_REPOS ]] && args+=(--exclude-repos="$EXCLUDE_REPOS")
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
        --supersede-reason)
            SUPERSEDE_REASON="$2"
            shift 2
            ;;
        --actor)
            ACTOR="$2"
            shift 2
            ;;
        --supersede)
            SUPERSEDE="true"
            shift
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
    local predecessor
    predecessor=$(stage_predecessor "$TARGET_STAGE") ||
        error "unknown target stage: ${TARGET_STAGE}. Expected DEV, TEST, STAGE, PREVIEW, INTERNAL or PROD"

    if [[ $SUPERSEDE == "true" && -z $SUPERSEDE_REASON ]]; then
        error "--supersede-reason is required with --supersede"
    fi

    local records
    records=$(jfrog_promotion_records "$BUNDLE_NAME" "$PROJECT") ||
        error "cannot promote without the promotion records for ${BUNDLE_NAME}"

    if version_is_at_stage "$records" "$VERSION" "$TARGET_STAGE"; then
        echo "${BUNDLE_NAME}/${VERSION} is already promoted to ${TARGET_STAGE}. Nothing to do." >&2
        exit 0
    fi

    if [[ -n $predecessor ]] && ! version_is_at_stage "$records" "$VERSION" "$predecessor"; then
        error "${BUNDLE_NAME}/${VERSION} is not promoted to ${predecessor}, so it cannot advance to ${TARGET_STAGE}"
    fi

    local incumbents
    incumbents=$(jfrog_versions_at_stage "$records" "$TARGET_STAGE" | grep -Fxv "$VERSION" || true)

    if [[ -n $incumbents ]]; then
        local incumbent_list
        incumbent_list=$(echo "$incumbents" | paste -sd, -)

        if [[ $SUPERSEDE != "true" ]]; then
            error "${TARGET_STAGE} already holds ${BUNDLE_NAME}/${incumbent_list}. Pass --supersede with --supersede-reason to replace it"
        fi

        if stage_is_frozen "$TARGET_STAGE"; then
            error "${TARGET_STAGE} is a released stage and cannot be superseded. ${BUNDLE_NAME}/${incumbent_list} is published; ship the fix as a new version"
        fi

        local stamp reason
        stamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        reason=$(sanitize_property_value "$SUPERSEDE_REASON")

        while IFS= read -r incumbent; do
            [[ -n $incumbent ]] || continue
            echo "Superseding ${BUNDLE_NAME}/${incumbent} at ${TARGET_STAGE}" >&2
            run jf release-bundle-delete-local "$BUNDLE_NAME" "$incumbent" "$TARGET_STAGE" \
                --project="$PROJECT" --quiet
            record_supersede "$incumbent" "$stamp" "$reason"
        done <<<"$incumbents"
    fi

    promote
    echo "Promoted ${BUNDLE_NAME}/${VERSION} to ${TARGET_STAGE}" >&2
}

main "$@"
