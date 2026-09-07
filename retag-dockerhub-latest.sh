#!/usr/bin/env bash
# Pull versioned Docker Hub images and push the same content as :latest.
#
# Org Docker Hub credentials live in the aerospike GitHub org
# (DOCKERHUB_USERNAME / DOCKERHUB_TOKEN) and cannot be read from a laptop.
# On a Mac this script dispatches the workflow that has those secrets.
set -euo pipefail

USERNAME="${DOCKERHUB_USERNAME:-aerospike}"
DRY_RUN="false"
SKIP_LOGIN="false"
DISPATCH="false"
DOCKER_MODE="false"
REPO="${GH_REPO:-aerospike/shared-workflows}"
WORKFLOW="example_retag-dockerhub-latest.yaml"

IMAGES=(
    aerospike/aerospike-asadm:5.0.3
    aerospike/aerospike-asbackup:4.5.8
    aerospike/aerospike-asbench:2.2.9
    aerospike/aerospike-asconfig:0.21.3
    aerospike/aerospike-aql:9.2.9
)

error() {
    echo "Error: $*" >&2
    exit 1
}

show_help() {
    cat <<EOF
Usage: $0 [OPTIONS]

Retag the pinned Docker Hub images as :latest.

Default on a Mac: dispatch ${WORKFLOW} on ${REPO}, which logs in with
org secrets DOCKERHUB_USERNAME / DOCKERHUB_TOKEN. Those values cannot be
downloaded locally.

Options:
  --dry-run       Print docker commands / dispatch with dry-run=true
  --dispatch      Force GitHub Actions dispatch (default on a laptop)
  --docker        Run docker pull/push on this machine (needs a token)
  --skip-login    Do not docker login (used by the Actions workflow)
  --help, -h      Show this help

Environment:
  GH_REPO              GitHub repo to dispatch (default: ${REPO})
  GH_REF               Git ref that contains the workflow (default: current branch)
  DOCKERHUB_TOKEN      Only for --docker
  DOCKERHUB_USERNAME   Only for --docker (default: aerospike)

Examples:
  $0 --dry-run
  $0
  DOCKERHUB_TOKEN='dckr_pat_...' $0 --docker
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --dry-run)
        DRY_RUN="true"
        shift
        ;;
    --dispatch)
        DISPATCH="true"
        shift
        ;;
    --docker)
        DOCKER_MODE="true"
        shift
        ;;
    --skip-login)
        SKIP_LOGIN="true"
        shift
        ;;
    --help | -h)
        show_help
        exit 0
        ;;
    *)
        error "Unknown argument: $1"
        ;;
    esac
done

if [[ $DISPATCH == true && $DOCKER_MODE == true ]]; then
    error "Cannot combine --dispatch and --docker"
fi

run() {
    if [[ $DRY_RUN == true ]]; then
        printf '[dry-run]'
        printf ' %q' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

current_ref() {
    if [[ -n ${GH_REF-} ]]; then
        printf '%s\n' "$GH_REF"
        return
    fi
    git rev-parse --abbrev-ref HEAD 2>/dev/null || printf 'main\n'
}

dispatch_workflow() {
    command -v gh >/dev/null 2>&1 || error "gh is not installed or not on PATH"
    gh auth status >/dev/null 2>&1 || error "gh is not logged in; run: gh auth login"

    local ref
    ref="$(current_ref)"
    local dry_input=false
    if [[ $DRY_RUN == true ]]; then
        dry_input=true
    fi

    echo "Dispatching ${WORKFLOW} on ${REPO}@${ref} (dry-run=${dry_input})"
    echo "This run uses org secrets DOCKERHUB_USERNAME / DOCKERHUB_TOKEN."

    local before=""
    before="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --branch "$ref" --limit 1 --json databaseId --jq '.[0].databaseId // empty' 2>/dev/null || true)"

    gh workflow run "$WORKFLOW" --repo "$REPO" --ref "$ref" -f "dry-run=${dry_input}"

    echo "Waiting for the workflow run to appear..."
    local rid=""
    local i
    for i in $(seq 1 30); do
        rid="$(gh run list --repo "$REPO" --workflow "$WORKFLOW" --branch "$ref" --limit 1 --json databaseId --jq '.[0].databaseId // empty')"
        if [[ -n $rid && $rid != "$before" ]]; then
            break
        fi
        rid=""
        sleep 2
    done

    [[ -n $rid ]] || error "Timed out waiting for workflow run on ${REPO}@${ref}. Push ${WORKFLOW} to that ref first."

    echo "Watching run ${rid}"
    gh run watch "$rid" --repo "$REPO" --exit-status
    echo "https://github.com/${REPO}/actions/runs/${rid}"
}

retag_with_docker() {
    command -v docker >/dev/null 2>&1 || error "docker is not installed or not on PATH"

    if [[ $SKIP_LOGIN != true && $DRY_RUN != true ]]; then
        if [[ -n ${DOCKERHUB_TOKEN-} ]]; then
            printf '%s\n' "$DOCKERHUB_TOKEN" | docker login --username "$USERNAME" --password-stdin
        else
            echo "Logging in to Docker Hub as ${USERNAME} (password/token will not be echoed)"
            docker login --username "$USERNAME"
        fi
    elif [[ $DRY_RUN == true && $SKIP_LOGIN != true ]]; then
        echo "[dry-run] would docker login --username ${USERNAME}"
    fi

    local src repo latest
    for src in "${IMAGES[@]}"; do
        repo="${src%:*}"
        latest="${repo}:latest"

        echo "==> $src -> $latest"
        run docker pull "$src"

        # imagetools copies the full manifest list (amd64+arm64) to :latest.
        # A local docker tag + push on macOS would publish only the pulled platform.
        if docker buildx imagetools --help >/dev/null 2>&1; then
            run docker buildx imagetools create --tag "$latest" "$src"
        else
            run docker tag "$src" "$latest"
            run docker push "$latest"
        fi
    done

    echo "Done. Pushed :latest for ${#IMAGES[@]} images."
}

if [[ $DOCKER_MODE == true || $SKIP_LOGIN == true || -n ${GITHUB_ACTIONS-} ]]; then
    retag_with_docker
else
    dispatch_workflow
fi
