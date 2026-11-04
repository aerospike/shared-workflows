#!/usr/bin/env bats
#
# Placement rules for gh-context-artifacts-json: what reaches the build context
# and what is refused before it can.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"

setup_file() {
    export SCRIPT_UNDER_TEST="${BATS_FILE_TMPDIR}/place.sh"
    yq -r '.jobs.build.steps[] | select(.name == "Place build-context artifacts") | .run' \
        "$WORKFLOW" > "$SCRIPT_UNDER_TEST"
}

setup() {
    RUNNER_TEMP="${BATS_TEST_TMPDIR}/runner"
    CONTEXT="${BATS_TEST_TMPDIR}/ctx"
    STAGING="${RUNNER_TEMP}/context-artifacts"
    mkdir -p "$STAGING" "$CONTEXT"
}

# Stages an artifact the way actions/download-artifact lays it out: a lone
# artifact is extracted into the path root, and only when several match does
# each get a directory named after it.
#
# artifact <name> [relative-file ...]; defaults to one regular file.
artifact() {
    local name="$1"
    shift
    _stage_into "${STAGING}/${name}" "$@"
}

# solo <relative-file ...>; the layout a single requested artifact gets.
solo() {
    _stage_into "$STAGING" "$@"
}

_stage_into() {
    local root="$1"
    shift
    mkdir -p "$root"
    if [ "$#" -eq 0 ]; then
        echo "payload" > "${root}/file.txt"
        return
    fi
    local f
    for f in "$@"; do
        mkdir -p "$(dirname "${root}/${f}")"
        echo "payload" > "${root}/${f}"
    done
}

restage() {
    rm -rf "${STAGING:?}" "${CONTEXT:?}"
    mkdir -p "$STAGING" "$CONTEXT"
}

place() {
    RUNNER_TEMP="$RUNNER_TEMP" \
        BUILD_CONTEXT="$CONTEXT" \
        CONTEXT_ARTIFACTS_ENTRIES="$1" \
        run bash "$SCRIPT_UNDER_TEST"
}

# refuse <json> <label>; fails the test if placement succeeds.
refuse() {
    place "$1"
    if [ "$status" -eq 0 ]; then
        echo "accepted: $2"
        return 1
    fi
}

@test "places one artifact's tree under a nested dest and reports it" {
    solo app.jar nested/deep/inner.txt
    place '[{"name":"signed-artifacts","dest":"deploy/chart/files"}]'
    [ "$status" -eq 0 ]
    [ -f "${CONTEXT}/deploy/chart/files/app.jar" ]
    [ -f "${CONTEXT}/deploy/chart/files/nested/deep/inner.txt" ]
    [[ $output == *'Placed "signed-artifacts" at "deploy/chart/files": 2 file(s), 16 byte(s)'* ]]
}

@test "places each entry's own content at its own dest" {
    mkdir -p "${STAGING}/alpha" "${STAGING}/beta"
    echo "alpha-content" > "${STAGING}/alpha/a.txt"
    echo "beta-content" > "${STAGING}/beta/b.txt"
    place '[{"name":"alpha","dest":"one"},{"name":"beta","dest":"two"}]'
    [ "$status" -eq 0 ]
    [ "$(cat "${CONTEXT}/one/a.txt")" = "alpha-content" ]
    [ "$(cat "${CONTEXT}/two/b.txt")" = "beta-content" ]
    [ ! -e "${CONTEXT}/one/b.txt" ]
    [ ! -e "${CONTEXT}/two/a.txt" ]
    [ "$(grep -c '^Placed ' <<<"$output")" = "2" ]
}

@test "fails when a requested artifact was not downloaded" {
    # A pattern that matches nothing leaves no staging directory at all.
    rm -rf "${STAGING:?}"
    refuse '[{"name":"signed-artifacts","dest":"x"}]' "nothing staged"
    [[ $output == *'"signed-artifacts" was not downloaded'* ]]

    # When only one of two requested artifacts matched, the action extracts it
    # into the staging root, so neither is where placement looks.
    restage && solo
    refuse '[{"name":"a","dest":"x"},{"name":"b","dest":"y"}]' "one of two staged at the root"

    restage && artifact good
    refuse '[{"name":"good","dest":"x"},{"name":"missing","dest":"y"}]' "second entry missing"
}

@test "refuses an artifact with no regular files or with a symlink, at any depth" {
    restage
    refuse '[{"name":"a","dest":"x"}]' "empty"

    restage && mkdir -p "${STAGING}/nested/deeper"
    refuse '[{"name":"a","dest":"x"}]' "only directories"

    # A regular file plus a symlink satisfies the emptiness check.
    restage && solo real.txt && ln -s /etc/passwd "${STAGING}/escape"
    refuse '[{"name":"a","dest":"x"}]' "top-level symlink"

    restage && solo real.txt nested/keep.txt && ln -s ../../../../etc/passwd "${STAGING}/nested/escape"
    refuse '[{"name":"a","dest":"x"}]' "nested symlink"
}

@test "refuses a dest that already exists" {
    restage && solo && mkdir -p "${CONTEXT}/x"
    refuse '[{"name":"a","dest":"x"}]' "existing directory"

    restage && solo && echo existing > "${CONTEXT}/x"
    refuse '[{"name":"a","dest":"x"}]' "existing file"

    restage && solo && ln -s /nonexistent "${CONTEXT}/x"
    refuse '[{"name":"a","dest":"x"}]' "dangling symlink"
}

@test "refuses a dest reached through a symlinked parent" {
    # link/out stays inside the context once resolved, so only the symlink
    # check refuses it.
    local dest
    for dest in vendor/out vendor/deep/out link/out; do
        restage && solo
        ln -s /tmp "${CONTEXT}/vendor"
        mkdir -p "${CONTEXT}/real" && ln -s real "${CONTEXT}/link"
        refuse "[{\"name\":\"a\",\"dest\":\"$dest\"}]" "$dest"
    done
}

@test "the containment guard refuses a dest that resolves outside the context" {
    # Validation rejects these first, so they are fed in directly to reach the
    # guard behind it. <ctx>-evil/x passes a bare prefix test against <ctx>.
    local dest
    for dest in ../escape good/../../escape "../$(basename "$CONTEXT")-evil/x"; do
        restage && solo
        refuse "[{\"name\":\"a\",\"dest\":\"$dest\"}]" "$dest"
        [[ $output == *"resolves outside the build context root"* ]]
    done
    [ ! -e "$(dirname "$CONTEXT")/escape" ]
    [ ! -e "${CONTEXT}-evil/x" ]
}

@test "fails when the build context does not exist" {
    solo
    CONTEXT="${BATS_TEST_TMPDIR}/absent"
    refuse '[{"name":"a","dest":"x"}]' "missing context"
}
