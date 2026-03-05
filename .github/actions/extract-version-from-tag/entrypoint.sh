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

# Default values — set here so tests can override before calling resolve_version()
VERSION_INPUT="${VERSION_INPUT-}"
TAG_PREFIX="${TAG_PREFIX:-v}"
VERSION_FILE="${VERSION_FILE:-VERSION}"
GITHUB_REF="${GITHUB_REF-}"
OUTPUT_FILE="${GITHUB_OUTPUT-}"

show_help() {
    echo "Usage: $0 [OPTIONS]" >&2
    echo "" >&2
    echo "Extracts version from explicit input, VERSION file, Git tag, or fallback." >&2
    echo "" >&2
    echo "Priority order:" >&2
    echo "  1. --version (explicit override)" >&2
    echo "  2. --version-file (VERSION file)" >&2
    echo "  3. Git tag (from GITHUB_REF)" >&2
    echo "  4. Fallback (git describe --tags, or 0.0.0-dev+<sha>)" >&2
    echo "" >&2
    echo "Options:" >&2
    echo "  --version <ver>          Explicit version override (highest priority)" >&2
    echo "  --version-file <path>    Path to VERSION file (default: VERSION)" >&2
    echo "  --tag-prefix <prefix>    Prefix to strip from version (default: v)" >&2
    # shellcheck disable=SC2016
    echo '  --github-ref <ref>       Git ref, e.g. refs/tags/v1.0.0 (default: $GITHUB_REF)' >&2
    # shellcheck disable=SC2016
    echo '  --output-file <path>     Output file for results (default: $GITHUB_OUTPUT)' >&2
    echo "  --help, -h               Show this help message" >&2
    echo "" >&2
    echo "Examples:" >&2
    echo "  $0 --version 1.0.0-dev" >&2
    echo "  $0 --version-file ./VERSION --tag-prefix release-" >&2
    echo "  $0 --github-ref refs/tags/v2.0.0" >&2
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
        --version)
            VERSION_INPUT="$2"
            shift 2
            ;;
        --version-file)
            VERSION_FILE="$2"
            shift 2
            ;;
        --tag-prefix)
            TAG_PREFIX="$2"
            shift 2
            ;;
        --github-ref)
            GITHUB_REF="$2"
            shift 2
            ;;
        --output-file)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        --help | -h)
            show_help
            exit 0
            ;;
        -*)
            echo "Unknown option: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
        *)
            echo "Unexpected positional argument: $1" >&2
            echo "Use --help for usage information" >&2
            exit 1
            ;;
        esac
    done
}

# Core version resolution logic.
# Sets: VERSION, GIT_TAG, SOURCE
resolve_version() {
    local tag=""
    local source=""

    if [[ -n $VERSION_INPUT ]]; then
        tag="$VERSION_INPUT"
        source="input"
    elif [[ -f $VERSION_FILE ]] && tag=$(tr -d '\n\r' <"$VERSION_FILE" | xargs) && [[ -n $tag ]]; then
        source="file"
    elif [[ $GITHUB_REF == refs/tags/* ]]; then
        tag="${GITHUB_REF##*/}"
        source="tag"
    else
        if tag=$(git describe --tags 2>/dev/null); then
            source="fallback"
        else
            local short_sha
            short_sha=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
            tag="0.0.0-dev+${short_sha}"
            source="fallback"
        fi
    fi

    # Strip prefix if present
    local version="$tag"
    if [[ $version == "${TAG_PREFIX}"* ]]; then
        version="${version#"${TAG_PREFIX}"}"
    fi

    VERSION="$version"
    GIT_TAG="$tag"
    SOURCE="$source"
}

main() {
    parse_args "$@"
    resolve_version

    echo "Final version: $VERSION (from: $SOURCE)" >&2

    if [[ -n $OUTPUT_FILE ]]; then
        {
            echo "version=$VERSION"
            echo "git_tag=$GIT_TAG"
            echo "source=$SOURCE"
        } >>"$OUTPUT_FILE"
    fi
}

# Only run main when executed directly (not sourced)
if [[ ${BASH_SOURCE[0]} == "${0}" ]]; then
    main "$@"
fi
