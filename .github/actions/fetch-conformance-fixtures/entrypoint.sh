#!/usr/bin/env bash
# Download one pinned aerospike-client-conformance release and extract it.
set -euo pipefail

export PS4='+($LINENO): ${FUNCNAME[0]:+${FUNCNAME[0]}(): }'
trap 'handle_error ${LINENO}' ERR

# shellcheck disable=SC2317
handle_error() {
    local exit_code=$?
    local line_number=$1
    echo "Error: command failed with exit code ${exit_code} at line ${line_number}" >&2
    exit "$exit_code"
}

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib.sh"

show_help() {
    cat <<'EOF'
Usage: entrypoint.sh <validate|fetch>

Downloads aerospike-client-conformance-<version>.zip from JFrog generic and
extracts it so the destination looks like a checkout of that release (VERSION
at the destination root).

Environment:
  VERSION              Fixture set version, MAJOR.MINOR.PATCH (required)
  PACKAGE_NAME         Artifact name (default: aerospike-client-conformance)
  JF_PROJECT           Artifactory project (default: database)
  DESTINATION          Workspace-relative directory (default: conformance-fixtures)
  DRY_RUN              true skips the download
  OIDC_PROVIDER_NAME   Required unless DRY_RUN=true
  OIDC_AUDIENCE        Required unless DRY_RUN=true
EOF
}

require_oidc() {
    if [[ -z ${OIDC_PROVIDER_NAME-} ]]; then
        error "oidc-provider-name is required unless dry-run is true"
    fi
    if [[ -z ${OIDC_AUDIENCE-} ]]; then
        error "oidc-audience is required unless dry-run is true"
    fi
}

validate_inputs() {
    local version=${VERSION-}
    local package=${PACKAGE_NAME:-aerospike-client-conformance}
    local project=${JF_PROJECT:-database}
    local destination=${DESTINATION:-conformance-fixtures}

    if [[ -z $version ]]; then
        error "version is required"
    fi
    validate_semver "$version"
    validate_token "package-name" "$package"
    validate_token "jf-project" "$project"
    resolve_destination "$destination" >/dev/null
    if ! is_dry_run; then
        require_oidc
    fi
}

write_output() {
    local name=$1
    local value=$2
    if [[ -n ${GITHUB_OUTPUT-} ]]; then
        printf '%s=%s\n' "$name" "$value" >>"$GITHUB_OUTPUT"
    fi
}

fetch_fixtures() {
    local version=${VERSION-}
    local package=${PACKAGE_NAME:-aerospike-client-conformance}
    local project=${JF_PROJECT:-database}
    local destination=${DESTINATION:-conformance-fixtures}
    local artifact dest workdir zip_name zip_path

    artifact=$(artifact_repo_path "$project" "$package" "$version")
    dest=$(resolve_destination "$destination")
    write_output artifact-path "$artifact"

    if is_dry_run; then
        echo "dry-run: jf rt download ${artifact} --flat=true --project=${project}"
        return 0
    fi

    local existing=""
    if [[ -d $dest ]]; then
        existing=$(find "$dest" -mindepth 1 -maxdepth 1 -print -quit)
    fi

    if [[ -n $existing ]]; then
        error "destination is not empty: $dest"
    fi

    if ! command -v jf >/dev/null 2>&1; then
        error "jf is not on PATH; the Set up JFrog CLI step did not run"
    fi

    workdir=$(mktemp -d)
    # shellcheck disable=SC2064
    trap "rm -rf '$workdir'" EXIT
    zip_name="${package}-${version}.zip"

    jf rt download "$artifact" "$workdir/" --flat=true --project="$project"
    zip_path="$workdir/$zip_name"
    if [[ ! -f $zip_path ]]; then
        echo "Download directory contents:" >&2
        find "$workdir" -print >&2 || true
        error "fixture zip was not downloaded: $artifact"
    fi

    # unzip already drops ../ from entry names, but it extracts symlinks as-is.
    local listing
    listing=$(unzip -Z "$zip_path")
    if grep -q '^l' <<<"$listing"; then
        error "release zip contains a symlink: $artifact"
    fi

    local staging="$workdir/extract"
    unzip -q "$zip_path" -d "$staging"

    local release_root="$staging/${package}-${version}"
    if [[ ! -f $release_root/VERSION ]]; then
        error "release zip has no ${package}-${version}/VERSION"
    fi

    local found_version
    found_version=$(tr -d '[:space:]' <"$release_root/VERSION")
    if [[ $found_version != "$version" ]]; then
        error "VERSION is ${found_version}, expected ${version}"
    fi

    mkdir -p "$dest"
    cp -R "$release_root/." "$dest/"

    write_output fixtures-directory "$dest"
    write_output fixture-set-version "$version"
    echo "Extracted fixture set ${version} to ${dest}"
}

main() {
    local command=${1:-fetch}
    case "$command" in
    validate)
        validate_inputs
        ;;
    fetch)
        fetch_fixtures
        ;;
    -h | --help | help)
        show_help
        ;;
    *)
        show_help >&2
        error "unknown command: $command"
        ;;
    esac
}

main "$@"
