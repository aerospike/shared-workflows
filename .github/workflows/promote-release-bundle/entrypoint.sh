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
SUPERSEDE="false"
SUPERSEDE_REASON=""
DRY_RUN="false"
RECORDS=""
BUNDLE_PATHS=""
INCUMBENTS=()

# DEV is optional: requiring it would lock the dev-local paths a rebuild deploys to.
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
    echo "Promote a JFrog release bundle version to a stage. STAGE requires TEST; PREVIEW, INTERNAL" >&2
    echo "and PROD require STAGE. A stage counts only when it holds every artifact of the version." >&2
    echo "With --supersede, versions at the stage that share an artifact path with this one are" >&2
    echo "un-promoted first, and a supersede record is written for the workflow to attest and store." >&2
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
    echo "  --supersede <reason>       Replace the versions at the stage that share a path with this" >&2
    echo "                             one. DEV, TEST and STAGE only" >&2
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

# Succeeds when completed promotions to the stage hold every artifact of the version.
holds_version() {
    local stage="$1" id held=""
    for id in $(jq -r --arg stage "$stage" \
        '.promotions[] | select(.status == "COMPLETED" and .environment == $stage) | .created_millis' <<<"$RECORDS"); do
        held+=$(jfrog_promotion_artifact_paths "$BUNDLE_NAME" "$VERSION" "$PROJECT" "$id") ||
            error "cannot read the ${stage} promotion ${id} of ${BUNDLE_NAME}/${VERSION}"
        held+=$'\n'
    done
    [[ -n $held ]] || return 1
    load_bundle_paths
    [[ -z $(LC_ALL=C comm -23 <(printf '%s\n' "$BUNDLE_PATHS") <(LC_ALL=C sort -u <<<"$held")) ]]
}

load_bundle_paths() {
    [[ -n $BUNDLE_PATHS ]] || BUNDLE_PATHS=$(jfrog_bundle_artifact_paths "$BUNDLE_NAME" "$VERSION" "$PROJECT") ||
        error "cannot promote without the artifact list of ${BUNDLE_NAME}/${VERSION}"
}

# Sets INCUMBENTS to the other versions at the target stage that share an artifact path with VERSION.
find_incumbents() {
    local versions version paths
    versions=$(jfrog_versions_at_stage "$BUNDLE_NAME" "$PROJECT" "$TARGET_STAGE") ||
        error "cannot supersede without the promotion records for ${BUNDLE_NAME}"
    for version in $versions; do
        [[ $version != "$VERSION" ]] || continue
        load_bundle_paths
        paths=$(jfrog_bundle_artifact_paths "$BUNDLE_NAME" "$version" "$PROJECT") ||
            error "cannot supersede without the artifact list of ${BUNDLE_NAME}/${version}"
        if [[ -n $(LC_ALL=C comm -12 <(printf '%s\n' "$BUNDLE_PATHS") <(printf '%s\n' "$paths")) ]]; then
            INCUMBENTS+=("$version")
        fi
    done
}

restore() {
    local incumbent lost=()
    for incumbent in "$@"; do
        echo "Re-promoting ${BUNDLE_NAME}/${incumbent} to ${TARGET_STAGE}" >&2
        jf release-bundle-promote "$BUNDLE_NAME" "$incumbent" "$TARGET_STAGE" --project="$PROJECT" ||
            lost+=("$incumbent")
    done
    if ((${#lost[@]})); then
        echo "::error::${TARGET_STAGE} no longer holds ${BUNDLE_NAME} ${lost[*]}. Promote it again by hand."
    fi
}

# Un-promotes the incumbents, then promotes VERSION. A failure re-promotes what was un-promoted.
supersede() {
    local incumbent removed=()
    for incumbent in "${INCUMBENTS[@]}"; do
        echo "Un-promoting ${BUNDLE_NAME}/${incumbent} from ${TARGET_STAGE}" >&2
        if ! run jf release-bundle-delete-local "$BUNDLE_NAME" "$incumbent" "$TARGET_STAGE" --project="$PROJECT" --quiet --sync; then
            restore "${removed[@]}"
            error "could not un-promote ${BUNDLE_NAME}/${incumbent} from ${TARGET_STAGE}"
        fi
        removed+=("$incumbent")
    done
    if ! promote; then
        restore "${removed[@]}"
        error "could not promote ${BUNDLE_NAME}/${VERSION} to ${TARGET_STAGE}"
    fi
}

# Writes the supersede record to a file, and its store path to the step outputs.
write_record() {
    local epoch file
    epoch=$(date -u +%s)
    file="${RUNNER_TEMP:-/tmp}/${epoch}-${VERSION}.json"
    jq -n \
        --arg project "$PROJECT" \
        --arg bundle "$BUNDLE_NAME" \
        --arg stage "$TARGET_STAGE" \
        --arg version "$VERSION" \
        --argjson epoch "$epoch" \
        --arg actor "${GITHUB_TRIGGERING_ACTOR-}" \
        --arg reason "$SUPERSEDE_REASON" \
        --arg run "${GITHUB_SERVER_URL-}/${GITHUB_REPOSITORY-}/actions/runs/${GITHUB_RUN_ID-}/attempts/${GITHUB_RUN_ATTEMPT-}" \
        '{schema: "https://aerospike.com/schemas/supersede/v1", project: $project, bundle: $bundle,
          stage: $stage, replaced: $ARGS.positional, replacedBy: $version, at: ($epoch | todate),
          actor: $actor, reason: $reason, run: $run}' \
        --args "${INCUMBENTS[@]}" >"$file"
    {
        echo "record-file=${file}"
        echo "record-path=release-evidence-local/evidence/supersede/${PROJECT}/${BUNDLE_NAME}/${TARGET_STAGE}/${epoch}-${VERSION}.json"
    } >>"${GITHUB_OUTPUT:-/dev/null}"
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
        --supersede)
            SUPERSEDE="true"
            SUPERSEDE_REASON="$2"
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

    TARGET_STAGE="${TARGET_STAGE^^}"
    local required
    required=$(stage_requires "$TARGET_STAGE") ||
        error "unknown target stage: ${TARGET_STAGE}. Expected DEV, TEST, STAGE, PREVIEW, INTERNAL or PROD"
    if [[ $SUPERSEDE == "true" ]]; then
        [[ -n $SUPERSEDE_REASON ]] || error "--supersede requires a reason"
        case "$TARGET_STAGE" in
        PREVIEW | INTERNAL | PROD) error "a version at ${TARGET_STAGE} cannot be superseded. Ship the fix as a new version" ;;
        esac
    fi

    RECORDS=$(jfrog_promotion_records "$BUNDLE_NAME" "$VERSION" "$PROJECT") ||
        error "cannot promote without the promotion records for ${BUNDLE_NAME}/${VERSION}"

    if holds_version "$TARGET_STAGE"; then
        echo "${BUNDLE_NAME}/${VERSION} is already promoted to ${TARGET_STAGE}. Nothing to do." >&2
        exit 0
    fi
    if [[ -n $required ]] && ! holds_version "$required"; then
        error "${BUNDLE_NAME}/${VERSION} is not fully promoted to ${required}, so it cannot be promoted to ${TARGET_STAGE}"
    fi

    if [[ $SUPERSEDE == "true" ]]; then
        find_incumbents
    fi
    local replacing=""
    if ((${#INCUMBENTS[@]})); then
        supersede
        [[ $DRY_RUN == "true" ]] || write_record
        replacing=" in place of ${INCUMBENTS[*]}"
    else
        promote
    fi
    if [[ $DRY_RUN == "true" ]]; then
        echo "Would promote ${BUNDLE_NAME}/${VERSION} to ${TARGET_STAGE}${replacing}" >&2
    else
        echo "Promoted ${BUNDLE_NAME}/${VERSION} to ${TARGET_STAGE}${replacing}" >&2
    fi
}

main "$@"
