#!/usr/bin/env bash
# Copy the hi test compile images onto test-docker-dev-local.
# test-docker-virtual rejects push. CI pulls the virtual path, which serves
# these tags when the virtual aggregates the local repo.
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

HOST="${HOST:-aerospike.jfrog.io}"
LOCAL_REPO="${LOCAL_REPO:-test-docker-dev-local}"
VIRTUAL_REPO="${VIRTUAL_REPO:-test-docker-virtual}"
DRY_RUN="false"
# Pushed per platform, then joined. imagetools create from Docker Hub uploads
# blobs with a PATCH Artifactory answers 400 to.
PLATFORMS=(linux/amd64 linux/arm64)

# Source on Docker Hub, destination path CI requests.
IMAGES=(
    "docker.io/library/ubuntu:22.04|library/ubuntu:22.04"
    "docker.io/library/rockylinux:9|rockylinux:9"
    "docker.io/library/ubuntu:24.04|library/ubuntu:24.04"
    "docker.io/library/ubuntu:20.04|library/ubuntu:20.04"
    "docker.io/library/debian:11|library/debian:11"
    "docker.io/library/debian:12|library/debian:12"
    "docker.io/library/debian:13|library/debian:13"
    "docker.io/library/rockylinux:8|rockylinux:8"
    "docker.io/library/amazonlinux:2023|amazonlinux:2023"
)

show_help() {
    echo "Usage: $0 [--dry-run]" >&2
    echo "" >&2
    echo "Copy hi Makefile base images to ${HOST}/${LOCAL_REPO} and check ${HOST}/${VIRTUAL_REPO}." >&2
    echo "Copies the multi-arch index. JF_USERNAME and a JFrog CLI access token are required" >&2
    echo "(JFROG_CLI_ACCESS_TOKEN, or a prompt). Docker Hub login is separate if pulls are rate limited." >&2
}

run() {
    if [[ $DRY_RUN == "true" ]]; then
        echo "+ $*"
    else
        "$@"
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --dry-run)
        DRY_RUN="true"
        shift
        ;;
    -h | --help)
        show_help
        exit 0
        ;;
    *)
        echo "Error: Unknown argument: $1" >&2
        show_help
        exit 1
        ;;
    esac
done

if [[ $DRY_RUN == "true" ]]; then
    echo "+ read -s JFrog CLI access token (or JFROG_CLI_ACCESS_TOKEN)"
    echo "+ docker login ${HOST} -u \${JF_USERNAME} --password-stdin"
else
    if [[ -z ${JF_USERNAME-} ]]; then
        echo "Error: JF_USERNAME is required" >&2
        exit 1
    fi
    token="${JFROG_CLI_ACCESS_TOKEN-}"
    if [[ -z $token ]]; then
        read -r -s -p "JFrog CLI access token: " token
        echo
    fi
    if [[ -z $token ]]; then
        echo "Error: JFrog CLI access token is required" >&2
        exit 1
    fi
    printf '%s' "$token" | docker login "$HOST" -u "$JF_USERNAME" --password-stdin
    unset token
fi

copy_image() {
    local src="$1"
    local dest="$2"
    local platform sanitized platform_tag
    local -a platform_tags=()

    for platform in "${PLATFORMS[@]}"; do
        sanitized="${platform//\//-}"
        platform_tag="${dest}-${sanitized}"
        echo "Pull ${src} (${platform})"
        run docker pull --platform "$platform" "$src"
        run docker tag "$src" "$platform_tag"
        echo "Push ${platform_tag}"
        run docker push "$platform_tag"
        platform_tags+=("$platform_tag")
    done

    echo "Index ${dest}"
    if [[ $DRY_RUN == "true" ]]; then
        echo "+ docker manifest rm ${dest}"
        echo "+ docker manifest create ${dest} ${platform_tags[*]}"
        echo "+ docker manifest push ${dest}"
        return
    fi
    docker manifest rm "$dest" >/dev/null 2>&1 || true
    docker manifest create "$dest" "${platform_tags[@]}"
    docker manifest push "$dest"
}

for pair in "${IMAGES[@]}"; do
    src="${pair%%|*}"
    dest_path="${pair#*|}"
    dest="${HOST}/${LOCAL_REPO}/${dest_path}"
    echo "Copy ${src} -> ${dest}"
    copy_image "$src" "$dest"
done

for pair in "${IMAGES[@]}"; do
    dest_path="${pair#*|}"
    virtual_ref="${HOST}/${VIRTUAL_REPO}/${dest_path}"
    if [[ $DRY_RUN == "true" ]]; then
        echo "+ docker buildx imagetools inspect ${virtual_ref}"
        continue
    fi
    if ! docker buildx imagetools inspect "$virtual_ref" >/dev/null; then
        echo "Error: ${virtual_ref} is not on the virtual. ${VIRTUAL_REPO} is not aggregating ${LOCAL_REPO}." >&2
        exit 1
    fi
    echo "visible: ${virtual_ref}"
done
