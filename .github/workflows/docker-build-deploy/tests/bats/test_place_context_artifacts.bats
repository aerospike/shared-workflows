#!/usr/bin/env bats
#
# Placement rules for gh-context-artifacts-json: what reaches the build context
# and what is refused before it can.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"
STEP_NAME="Place build-context artifacts"

setup_file() {
    export SCRIPT_UNDER_TEST="${BATS_FILE_TMPDIR}/place.sh"
    yq -r ".jobs.build.steps[] | select(.name == \"$STEP_NAME\") | .run" \
        "$WORKFLOW" > "$SCRIPT_UNDER_TEST"
}

setup() {
    RUNNER_TEMP="${BATS_TEST_TMPDIR}/runner"
    CONTEXT="${BATS_TEST_TMPDIR}/ctx"
    STAGING="${RUNNER_TEMP}/context-artifacts"
    mkdir -p "$STAGING" "$CONTEXT"
}

# artifact <name> [relative-file ...]; defaults to one regular file.
artifact() {
    local name="$1"
    shift
    mkdir -p "${STAGING}/${name}"
    if [ "$#" -eq 0 ]; then
        echo "payload" > "${STAGING}/${name}/file.txt"
        return
    fi
    local f
    for f in "$@"; do
        mkdir -p "$(dirname "${STAGING}/${name}/${f}")"
        echo "payload" > "${STAGING}/${name}/${f}"
    done
}

place() {
    RUNNER_TEMP="$RUNNER_TEMP" \
        BUILD_CONTEXT="$CONTEXT" \
        CONTEXT_ARTIFACTS_ENTRIES="$1" \
        run bash "$SCRIPT_UNDER_TEST"
}

@test "the step this suite tests still exists in the workflow" {
    [ -s "$SCRIPT_UNDER_TEST" ]
}

@test "no caller-supplied value is interpolated into the script" {
    run grep -n '\${{' "$SCRIPT_UNDER_TEST"
    [ "$status" -ne 0 ]
}

# --- placement ------------------------------------------------------------

@test "places an artifact's files at the destination" {
    artifact signed-artifacts app.jar app.jar.asc
    place '[{"name":"signed-artifacts","dest":"artifacts"}]'
    [ "$status" -eq 0 ]
    [ -f "${CONTEXT}/artifacts/app.jar" ]
    [ -f "${CONTEXT}/artifacts/app.jar.asc" ]
}

@test "leaves nothing behind in staging" {
    artifact a
    place '[{"name":"a","dest":"x"}]'
    [ "$status" -eq 0 ]
    [ ! -e "${STAGING}/a" ]
}

@test "creates intermediate directories for a nested destination" {
    artifact a
    place '[{"name":"a","dest":"deploy/chart/files"}]'
    [ "$status" -eq 0 ]
    [ -f "${CONTEXT}/deploy/chart/files/file.txt" ]
}

@test "preserves the artifact's own directory structure" {
    artifact a top.txt nested/deep/inner.txt
    place '[{"name":"a","dest":"x"}]'
    [ "$status" -eq 0 ]
    [ -f "${CONTEXT}/x/top.txt" ]
    [ -f "${CONTEXT}/x/nested/deep/inner.txt" ]
}

@test "places each entry's own content at its own destination" {
    mkdir -p "${STAGING}/alpha" "${STAGING}/beta"
    echo "alpha-content" > "${STAGING}/alpha/a.txt"
    echo "beta-content" > "${STAGING}/beta/b.txt"
    place '[{"name":"alpha","dest":"one"},{"name":"beta","dest":"two"}]'
    [ "$status" -eq 0 ]
    [ "$(cat "${CONTEXT}/one/a.txt")" = "alpha-content" ]
    [ "$(cat "${CONTEXT}/two/b.txt")" = "beta-content" ]
    [ ! -e "${CONTEXT}/one/b.txt" ]
    [ ! -e "${CONTEXT}/two/a.txt" ]
}

# --- what the log reports -------------------------------------------------

@test "reports the artifact, destination and counts" {
    artifact a one.txt two.txt
    place '[{"name":"a","dest":"x"}]'
    [ "$status" -eq 0 ]
    [[ $output == *'Placed "a" at "x"'* ]]
    [[ $output == *"2 file(s)"* ]]
}

@test "counts files at any depth, not just the top level" {
    artifact a top.txt nested/deep/inner.txt
    place '[{"name":"a","dest":"x"}]'
    [[ $output == *"2 file(s)"* ]]
}

@test "reports byte totals" {
    artifact a
    place '[{"name":"a","dest":"x"}]'
    [[ $output == *"8 byte(s)"* ]]
}

@test "reports one line per artifact" {
    artifact a
    artifact b
    place '[{"name":"a","dest":"x"},{"name":"b","dest":"y"}]'
    [ "$(grep -c '^Placed ' <<<"$output")" = "2" ]
}

# --- refusals -------------------------------------------------------------

@test "fails and names the artifact when it was never downloaded" {
    place '[{"name":"signed-artifacts","dest":"x"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"signed-artifacts"* ]]
    [[ $output == *"was not downloaded"* ]]
}

@test "fails when the artifact holds no regular files at any depth" {
    for shape in flat nested; do
        rm -rf "${STAGING:?}"/*
        [ "$shape" = flat ] && mkdir -p "${STAGING}/a" || mkdir -p "${STAGING}/a/nested/deeper"
        place '[{"name":"a","dest":"x"}]'
        if [ "$status" -eq 0 ]; then
            echo "accepted an artifact with no regular files ($shape)"
            return 1
        fi
        [[ $output == *"no regular files"* ]]
    done
}

@test "fails when the artifact contains a symlink at any depth" {
    # A lone regular file plus a symlink satisfies the emptiness check, so the
    # symlink would ride into the image with it.
    for where in top nested; do
        rm -rf "${STAGING:?}"/* && artifact a real.txt
        if [ "$where" = top ]; then
            ln -s /etc/passwd "${STAGING}/a/escape"
        else
            mkdir -p "${STAGING}/a/nested"
            ln -s ../../../../etc/passwd "${STAGING}/a/nested/escape"
        fi
        place '[{"name":"a","dest":"x"}]'
        if [ "$status" -eq 0 ]; then
            echo "carried a symlink into the context ($where)"
            return 1
        fi
        [[ $output == *"non-regular file"* ]]
    done
}

@test "nothing is placed when one entry fails validation" {
    artifact good
    place '[{"name":"good","dest":"x"},{"name":"missing","dest":"y"}]'
    [ "$status" -ne 0 ]
    [ ! -e "${CONTEXT}/y" ]
}

# --- destination safety ---------------------------------------------------

@test "fails when the destination already exists" {
    for setup in dir file dangling; do
        rm -rf "${CONTEXT:?}"/* && artifact a
        case "$setup" in
            dir) mkdir -p "${CONTEXT}/x" ;;
            file) echo existing > "${CONTEXT}/x" ;;
            dangling) ln -s /nonexistent "${CONTEXT}/x" ;;
        esac
        place '[{"name":"a","dest":"x"}]'
        if [ "$status" -eq 0 ]; then
            echo "overwrote an existing destination ($setup)"
            return 1
        fi
        [[ $output == *"already exists"* ]]
    done
}

@test "refuses a destination reached through a symlinked parent" {
    # realpath -m resolves through existing symlinks, so following one would
    # land outside the context while still looking contained.
    for dest in vendor/out vendor/deep/out link/out; do
        rm -rf "${CONTEXT:?}"/* && artifact a
        ln -s /tmp "${CONTEXT}/vendor"
        mkdir -p "${CONTEXT}/real" && ln -s real "${CONTEXT}/link"
        place "[{\"name\":\"a\",\"dest\":\"$dest\"}]"
        if [ "$status" -eq 0 ]; then
            echo "followed a symlinked parent: $dest"
            return 1
        fi
        [[ $output == *"traverses a symlink"* ]]
    done
}

@test "a sibling directory sharing the context root prefix is not inside it" {
    # /tmp/.../ctx-evil must not pass a containment check against /tmp/.../ctx
    artifact a
    mkdir -p "${CONTEXT}-evil"
    ln -s "${CONTEXT}-evil" "${CONTEXT}/out"
    place '[{"name":"a","dest":"out"}]'
    [ "$status" -ne 0 ]
    [ ! -e "${CONTEXT}-evil/file.txt" ]
}

# Validation rejects these before placement sees them, so they are fed in
# directly to reach the containment guard behind it.

@test "containment guard rejects a traversing dest that skipped validation" {
    artifact a
    place '[{"name":"a","dest":"../escape"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"resolves outside the build context root"* ]]
    [ ! -e "$(dirname "$CONTEXT")/escape" ]
}

@test "containment guard rejects an interior traversal that skipped validation" {
    artifact a
    place '[{"name":"a","dest":"good/../../escape"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"resolves outside the build context root"* ]]
}

@test "containment guard rejects a sibling whose name merely extends the context root" {
    # Resolves to <ctx>-evil/x, which a bare prefix test against <ctx> accepts.
    artifact a
    place "[{\"name\":\"a\",\"dest\":\"../$(basename "$CONTEXT")-evil/x\"}]"
    [ "$status" -ne 0 ]
    [[ $output == *"resolves outside the build context root"* ]]
    [ ! -e "${CONTEXT}-evil/x" ]
}

@test "fails when the build context does not exist" {
    artifact a
    CONTEXT="${BATS_TEST_TMPDIR}/absent"
    place '[{"name":"a","dest":"x"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"is not a directory"* ]]
}
