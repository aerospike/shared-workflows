#!/usr/bin/env bats
#
# Rules for the gh-context-artifacts-json input.
#
# Do not move this script to a .sh file: a reusable workflow cannot check out
# its own repository to reach one. See docs/why-gh-workflows-ref.md.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"
STEP_NAME="Validate build-context artifacts"

setup_file() {
    export SCRIPT_UNDER_TEST="${BATS_FILE_TMPDIR}/validate.sh"
    yq -r ".jobs.build.steps[] | select(.name == \"$STEP_NAME\") | .run" \
        "$WORKFLOW" > "$SCRIPT_UNDER_TEST"
}

# validate <json>; leaves the step's outputs in $GITHUB_OUTPUT.
validate() {
    export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
    : > "$GITHUB_OUTPUT"
    CONTEXT_ARTIFACTS_JSON="$1" run bash "$SCRIPT_UNDER_TEST"
}

output_value() {
    grep "^$1=" "$GITHUB_OUTPUT" | cut -d= -f2-
}

# reject_all reads one JSON input per line from stdin and fails naming every
# input the validator wrongly accepted, rather than only the first.
reject_all() {
    local bad=0 json
    while read -r json; do
        [ -z "$json" ] && continue
        validate "$json"
        if [ "$status" -eq 0 ]; then
            echo "accepted but must reject: $json"
            bad=$((bad + 1))
        fi
    done
    [ "$bad" -eq 0 ]
}

accept_all() {
    local bad=0 json
    while read -r json; do
        [ -z "$json" ] && continue
        validate "$json"
        if [ "$status" -ne 0 ]; then
            echo "rejected but must accept: $json ($output)"
            bad=$((bad + 1))
        fi
    done
    [ "$bad" -eq 0 ]
}

@test "the step this suite tests still exists in the workflow" {
    [ -s "$SCRIPT_UNDER_TEST" ]
}

@test "no caller-supplied value is interpolated into the script" {
    # Interpolation happens before bash sees a quote, so env: is the only
    # safe channel for a caller-supplied value.
    run grep -n '\${{' "$SCRIPT_UNDER_TEST"
    [ "$status" -ne 0 ]
}

# --- accepted -------------------------------------------------------------

@test "accepts valid entries" {
    accept_all <<'CASES'
[{"name":"signed-artifacts","dest":"artifacts"}]
[{"name":"a","dest":"x"},{"name":"b","dest":"y"},{"name":"c","dest":"z"}]
[{"name":"a","dest":"deploy/chart/files"}]
[{"name":"a.b_c-1","dest":"a..b"}]
[{"name":"a","dest":"my-dir/sub-dir"}]
CASES
}

@test "an empty array is a no-op, not a failure" {
    validate '[]'
    [ "$status" -eq 0 ]
    [ "$(output_value count)" = "0" ]
}

@test "reports how many entries it accepted" {
    validate '[{"name":"a","dest":"x"},{"name":"b","dest":"y"}]'
    [ "$(output_value count)" = "2" ]
}

# --- download pattern -----------------------------------------------------

@test "a single entry emits a bare name, not a one-element brace" {
    # minimatch does not expand "{a}", so it would match that literal string
    # and download nothing.
    validate '[{"name":"signed-artifacts","dest":"x"}]'
    [ "$(output_value pattern)" = "signed-artifacts" ]
}

@test "two or more entries brace-expand" {
    validate '[{"name":"a","dest":"x"},{"name":"b","dest":"y"}]'
    [ "$(output_value pattern)" = "{a,b}" ]
    validate '[{"name":"a","dest":"x"},{"name":"b","dest":"y"},{"name":"c","dest":"z"}]'
    [ "$(output_value pattern)" = "{a,b,c}" ]
}

# --- rejected -------------------------------------------------------------

@test "rejects input that is not an array of two-string objects" {
    reject_all <<'CASES'
nonsense
{"name":"a","dest":"x"}
"hello"
["signed-artifacts"]
[{"dest":"x"}]
[{"name":"a"}]
[{"name":"","dest":"x"}]
[{"name":"a","dest":""}]
[{"name":123,"dest":"x"}]
[{"name":null,"dest":"x"}]
CASES
}

@test "names the offending entry index" {
    validate '[{"name":"a","dest":"x"},{"dest":"y"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"entry 1"* ]]
}

@test "rejects a name outside the permitted charset" {
    reject_all <<'CASES'
[{"name":"a/b","dest":"x"}]
[{"name":"a*","dest":"x"}]
[{"name":"a{b","dest":"x"}]
[{"name":"a b","dest":"x"}]
CASES
}

@test 'rejects a name of "." or ".."' {
    # Both pass the charset. download-artifact joins the name onto the staging
    # path, so ".." resolves it to RUNNER_TEMP.
    for n in . ..; do
        validate "[{\"name\":\"$n\",\"dest\":\"x\"}]"
        [ "$status" -ne 0 ]
        [[ $output == *"path traversal"* ]]
    done
}

@test "rejects a dest that escapes or reaches outside the context" {
    reject_all <<'CASES'
[{"name":"a","dest":"/etc/passwd"}]
[{"name":"a","dest":"."}]
[{"name":"a","dest":".."}]
[{"name":"a","dest":"../escape"}]
[{"name":"a","dest":"good/../../escape"}]
[{"name":"a","dest":"good/.."}]
[{"name":"a","dest":"good/./x"}]
CASES
}

@test "rejects a dest segment that a utility would read as an option" {
    reject_all <<'CASES'
[{"name":"a","dest":"-rf"}]
[{"name":"a","dest":"good/-rf"}]
[{"name":"a","dest":"--no-preserve-root"}]
CASES
    validate '[{"name":"a","dest":"-rf"}]'
    [[ $output == *'beginning with "-"'* ]]
}

@test "rejects a dest outside the permitted charset" {
    reject_all <<'CASES'
[{"name":"a","dest":"my dir"}]
[{"name":"a","dest":"x`id`"}]
[{"name":"a","dest":"x$HOME"}]
CASES
}

@test "rejects a malformed path shape" {
    reject_all <<'CASES'
[{"name":"a","dest":"good//bad"}]
[{"name":"a","dest":"good/"}]
CASES
    validate '[{"name":"a","dest":"good/"}]'
    [[ $output == *'must not end with "/"'* ]]
}

@test "rejects duplicates, including two dests naming one directory" {
    reject_all <<'CASES'
[{"name":"a","dest":"x"},{"name":"a","dest":"y"}]
[{"name":"a","dest":"x"},{"name":"b","dest":"x"}]
[{"name":"a","dest":"x"},{"name":"b","dest":"x/"}]
CASES
}
