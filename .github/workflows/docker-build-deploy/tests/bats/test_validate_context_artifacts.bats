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

@test "accepts a single entry" {
    validate '[{"name":"signed-artifacts","dest":"artifacts"}]'
    [ "$status" -eq 0 ]
    [ "$(output_value count)" = "1" ]
}

@test "accepts several entries" {
    validate '[{"name":"a","dest":"x"},{"name":"b","dest":"y"},{"name":"c","dest":"z"}]'
    [ "$status" -eq 0 ]
    [ "$(output_value count)" = "3" ]
}

@test "an empty array is a no-op, not a failure" {
    validate '[]'
    [ "$status" -eq 0 ]
    [ "$(output_value count)" = "0" ]
}

@test "accepts a nested dest" {
    validate '[{"name":"a","dest":"deploy/chart/files"}]'
    [ "$status" -eq 0 ]
}

@test "accepts dots inside a segment, which are not traversal" {
    validate '[{"name":"a.b_c-1","dest":"a..b"}]'
    [ "$status" -eq 0 ]
}

@test "accepts a dash inside a segment, which is not an option" {
    validate '[{"name":"a","dest":"my-dir/sub-dir"}]'
    [ "$status" -eq 0 ]
}

# --- download pattern -----------------------------------------------------

@test "a single entry emits a bare name, because minimatch does not expand a one-element brace" {
    validate '[{"name":"signed-artifacts","dest":"x"}]'
    [ "$(output_value pattern)" = "signed-artifacts" ]
}

@test "two entries brace-expand" {
    validate '[{"name":"a","dest":"x"},{"name":"b","dest":"y"}]'
    [ "$(output_value pattern)" = "{a,b}" ]
}

@test "three entries brace-expand" {
    validate '[{"name":"a","dest":"x"},{"name":"b","dest":"y"},{"name":"c","dest":"z"}]'
    [ "$(output_value pattern)" = "{a,b,c}" ]
}

# --- rejected: structure --------------------------------------------------

@test "rejects input that is not JSON" {
    validate 'nonsense'
    [ "$status" -ne 0 ]
    [[ $output == *"not valid JSON"* ]]
}

@test "rejects a JSON object" {
    validate '{"name":"a","dest":"x"}'
    [ "$status" -ne 0 ]
    [[ $output == *"must be a JSON array"* ]]
}

@test "rejects a JSON string" {
    validate '"hello"'
    [ "$status" -ne 0 ]
}

@test "rejects an entry that is not an object" {
    validate '["signed-artifacts"]'
    [ "$status" -ne 0 ]
}

@test "rejects a missing name" {
    validate '[{"dest":"x"}]'
    [ "$status" -ne 0 ]
}

@test "rejects a missing dest" {
    validate '[{"name":"a"}]'
    [ "$status" -ne 0 ]
}

@test "rejects an empty name" {
    validate '[{"name":"","dest":"x"}]'
    [ "$status" -ne 0 ]
}

@test "rejects an empty dest" {
    validate '[{"name":"a","dest":""}]'
    [ "$status" -ne 0 ]
}

@test "rejects a non-string name" {
    validate '[{"name":123,"dest":"x"}]'
    [ "$status" -ne 0 ]
}

@test "rejects a null name" {
    validate '[{"name":null,"dest":"x"}]'
    [ "$status" -ne 0 ]
}

@test "names the offending entry index" {
    validate '[{"name":"a","dest":"x"},{"dest":"y"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"entry 1"* ]]
}

# --- rejected: name -------------------------------------------------------

@test 'rejects a name of "." which the charset alone permits' {
    validate '[{"name":".","dest":"x"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"path traversal"* ]]
}

@test 'rejects a name of ".." which would resolve the staging dir to RUNNER_TEMP' {
    validate '[{"name":"..","dest":"x"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"path traversal"* ]]
}

@test "rejects a name containing a slash" {
    validate '[{"name":"a/b","dest":"x"}]'
    [ "$status" -ne 0 ]
}

@test "rejects a name containing a glob star" {
    validate '[{"name":"a*","dest":"x"}]'
    [ "$status" -ne 0 ]
}

@test "rejects a name containing a brace, which would corrupt the download pattern" {
    validate '[{"name":"a{b","dest":"x"}]'
    [ "$status" -ne 0 ]
}

@test "rejects a name containing a space" {
    validate '[{"name":"a b","dest":"x"}]'
    [ "$status" -ne 0 ]
}

@test "rejects a duplicate name" {
    validate '[{"name":"a","dest":"x"},{"name":"a","dest":"y"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"duplicate"* ]]
}

# --- rejected: dest -------------------------------------------------------

@test "rejects an absolute dest" {
    validate '[{"name":"a","dest":"/etc/passwd"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"relative to the build context root"* ]]
}

@test 'rejects a dest of "."' {
    validate '[{"name":"a","dest":"."}]'
    [ "$status" -ne 0 ]
}

@test 'rejects a dest of ".."' {
    validate '[{"name":"a","dest":".."}]'
    [ "$status" -ne 0 ]
}

@test "rejects a leading traversal" {
    validate '[{"name":"a","dest":"../escape"}]'
    [ "$status" -ne 0 ]
}

@test "rejects an interior traversal" {
    validate '[{"name":"a","dest":"good/../../escape"}]'
    [ "$status" -ne 0 ]
}

@test "rejects a trailing traversal" {
    validate '[{"name":"a","dest":"good/.."}]'
    [ "$status" -ne 0 ]
}

@test "rejects a current-directory segment" {
    validate '[{"name":"a","dest":"good/./x"}]'
    [ "$status" -ne 0 ]
}

@test "rejects an option-like dest, which mv would read as a flag" {
    validate '[{"name":"a","dest":"-rf"}]'
    [ "$status" -ne 0 ]
    [[ $output == *'beginning with "-"'* ]]
}

@test "rejects an option-like segment" {
    validate '[{"name":"a","dest":"good/-rf"}]'
    [ "$status" -ne 0 ]
}

@test "rejects a long option" {
    validate '[{"name":"a","dest":"--no-preserve-root"}]'
    [ "$status" -ne 0 ]
}

@test "rejects an empty segment from a doubled slash" {
    validate '[{"name":"a","dest":"good//bad"}]'
    [ "$status" -ne 0 ]
}

@test "rejects a trailing slash, which splitting on / would otherwise hide" {
    validate '[{"name":"a","dest":"good/"}]'
    [ "$status" -ne 0 ]
    [[ $output == *'must not end with "/"'* ]]
}

@test "rejects a dest containing a space" {
    validate '[{"name":"a","dest":"my dir"}]'
    [ "$status" -ne 0 ]
}

@test "rejects a dest containing a backtick" {
    validate '[{"name":"a","dest":"x`id`"}]'
    [ "$status" -ne 0 ]
}

@test "rejects a dest containing a dollar sign" {
    validate '[{"name":"a","dest":"x$HOME"}]'
    [ "$status" -ne 0 ]
}

@test "rejects a duplicate dest" {
    validate '[{"name":"a","dest":"x"},{"name":"b","dest":"x"}]'
    [ "$status" -ne 0 ]
    [[ $output == *"duplicate"* ]]
}

@test "rejects two dests naming the same directory via a trailing slash" {
    validate '[{"name":"a","dest":"x"},{"name":"b","dest":"x/"}]'
    [ "$status" -ne 0 ]
}
