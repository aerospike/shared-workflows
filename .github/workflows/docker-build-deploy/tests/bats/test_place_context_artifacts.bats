#!/usr/bin/env bats
#
# Placement rules for gh-context-artifacts-json: what reaches the build context
# and what is refused before it can.
#
# As with the validation suite, the script is extracted from the workflow rather
# than copied, so these cases exercise the text that ships.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"
STEP_NAME="Place build-context artifacts"

setup_file() {
    export SCRIPT_UNDER_TEST="${BATS_FILE_TMPDIR}/place.sh"
    python3 -c '
import sys, yaml
with open(sys.argv[1]) as fh:
    doc = yaml.safe_load(fh)
for step in doc["jobs"]["build"]["steps"]:
    if step.get("name") == sys.argv[2]:
        sys.stdout.write(step["run"])
        sys.exit(0)
sys.stderr.write("step not found: %s\n" % sys.argv[2])
sys.exit(1)
' "$WORKFLOW" "$STEP_NAME" > "$SCRIPT_UNDER_TEST"
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
#
# The log line is the only record of what was placed, so it is what a consumer
# reads when a build looks wrong. These assert it says something true.

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

@test "fails when the artifact holds no regular files" {
    mkdir -p "${STAGING}/a"
    place '[{"name":"a","dest":"x"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"no regular files"* ]]
}

@test "fails when the artifact holds only empty subdirectories" {
    mkdir -p "${STAGING}/a/nested/deeper"
    place '[{"name":"a","dest":"x"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"no regular files"* ]]
}

@test "fails when the artifact contains a symlink alongside a regular file" {
    artifact a real.txt
    ln -s /etc/passwd "${STAGING}/a/escape"
    place '[{"name":"a","dest":"x"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"non-regular file"* ]]
}

@test "fails when the artifact contains a symlink nested deep" {
    artifact a real.txt
    mkdir -p "${STAGING}/a/nested"
    ln -s ../../../../etc/passwd "${STAGING}/a/nested/escape"
    place '[{"name":"a","dest":"x"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"non-regular file"* ]]
}

@test "nothing is placed when one entry fails validation" {
    artifact good
    place '[{"name":"good","dest":"x"},{"name":"missing","dest":"y"}]'
    [ "$status" -ne 0 ]
    [ ! -e "${CONTEXT}/y" ]
}

# --- destination safety ---------------------------------------------------

@test "fails when the destination already exists as a directory" {
    artifact a
    mkdir -p "${CONTEXT}/x"
    place '[{"name":"a","dest":"x"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"already exists"* ]]
}

@test "fails when the destination already exists as a file" {
    artifact a
    echo "existing" > "${CONTEXT}/x"
    place '[{"name":"a","dest":"x"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"already exists"* ]]
}

@test "fails when the destination is a dangling symlink" {
    artifact a
    ln -s /nonexistent "${CONTEXT}/x"
    place '[{"name":"a","dest":"x"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"already exists"* ]]
}

@test "refuses a destination whose parent is a symlink out of the context" {
    artifact a
    ln -s /tmp "${CONTEXT}/vendor"
    place '[{"name":"a","dest":"vendor/out"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"traverses a symlink"* ]]
}

@test "refuses a destination whose grandparent is a symlink" {
    artifact a
    ln -s /tmp "${CONTEXT}/vendor"
    place '[{"name":"a","dest":"vendor/deep/out"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"traverses a symlink"* ]]
}

@test "a symlinked parent is refused even when it points back inside the context" {
    artifact a
    mkdir -p "${CONTEXT}/real"
    ln -s real "${CONTEXT}/link"
    place '[{"name":"a","dest":"link/out"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"traverses a symlink"* ]]
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

# The validate step rejects these destinations before placement ever sees them.
# These cases feed them in directly, so the containment guard is exercised as
# the independent second layer it exists to be. Without them, deleting that
# guard breaks no test.

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
