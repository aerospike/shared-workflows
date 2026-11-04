#!/usr/bin/env bats
#
# Rules for the gh-context-artifacts-json input.
#
# Do not move this script to a .sh file: a reusable workflow cannot check out
# its own repository to reach one. See docs/why-gh-workflows-ref.md.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"

setup_file() {
    export SCRIPT_UNDER_TEST="${BATS_FILE_TMPDIR}/validate.sh"
    yq -r '.jobs.build.steps[] | select(.name == "Validate build-context artifacts") | .run' \
        "$WORKFLOW" > "$SCRIPT_UNDER_TEST"
}

# validate <json>; leaves the step's outputs in $GITHUB_OUTPUT.
validate() {
    export GITHUB_OUTPUT="${BATS_TEST_TMPDIR}/github_output"
    : > "$GITHUB_OUTPUT"
    CONTEXT_ARTIFACTS_JSON="$1" run bash "$SCRIPT_UNDER_TEST" </dev/null
}

output_value() {
    grep "^$1=" "$GITHUB_OUTPUT" | cut -d= -f2-
}

# reject_all and accept_all read one JSON input per line from stdin and fail
# naming every input that got the wrong verdict, not only the first.
reject_all() {
    local bad=0 json
    while read -r json; do
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
        validate "$json"
        if [ "$status" -ne 0 ]; then
            echo "rejected but must accept: $json ($output)"
            bad=$((bad + 1))
        fi
    done
    [ "$bad" -eq 0 ]
}

@test "accepts valid entries and reports how many" {
    accept_all <<'CASES'
[]
[{"name":"signed-artifacts","dest":"artifacts"}]
[{"name":"a","dest":"x"},{"name":"b","dest":"y"},{"name":"c","dest":"z"}]
[{"name":"a","dest":"deploy/chart/files"}]
[{"name":"a.b_c-1","dest":"a..b"}]
[{"name":"a","dest":"my-dir/sub-dir"}]
CASES
    validate '[]'
    [ "$(output_value count)" = "0" ]
    validate '[{"name":"a","dest":"x"},{"name":"b","dest":"y"}]'
    [ "$(output_value count)" = "2" ]
}

@test "the download pattern is a bare name for one entry and a brace list for several" {
    # minimatch does not expand "{a}", so it would match that literal string
    # and download nothing.
    validate '[{"name":"signed-artifacts","dest":"x"}]'
    [ "$(output_value pattern)" = "signed-artifacts" ]
    validate '[{"name":"a","dest":"x"},{"name":"b","dest":"y"},{"name":"c","dest":"z"}]'
    [ "$(output_value pattern)" = "{a,b,c}" ]
}

@test "rejects input that is not an array of two-string objects, naming the entry" {
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
    validate '[{"name":"a","dest":"x"},{"dest":"y"}]'
    [[ $output == *"entry 1"* ]]
}

@test "rejects an unsafe name" {
    # "." and ".." pass the charset. download-artifact joins the name onto the
    # staging path, so ".." resolves it to RUNNER_TEMP.
    reject_all <<'CASES'
[{"name":"a/b","dest":"x"}]
[{"name":"a*","dest":"x"}]
[{"name":"a{b","dest":"x"}]
[{"name":"a b","dest":"x"}]
[{"name":".","dest":"x"}]
[{"name":"..","dest":"x"}]
CASES
}

@test "rejects an unsafe dest" {
    reject_all <<'CASES'
[{"name":"a","dest":"/etc/passwd"}]
[{"name":"a","dest":"."}]
[{"name":"a","dest":".."}]
[{"name":"a","dest":"../escape"}]
[{"name":"a","dest":"good/../../escape"}]
[{"name":"a","dest":"good/.."}]
[{"name":"a","dest":"good/./x"}]
[{"name":"a","dest":"-rf"}]
[{"name":"a","dest":"good/-rf"}]
[{"name":"a","dest":"--no-preserve-root"}]
[{"name":"a","dest":"my dir"}]
[{"name":"a","dest":"x`id`"}]
[{"name":"a","dest":"x$HOME"}]
[{"name":"a","dest":"good//bad"}]
[{"name":"a","dest":"good/"}]
CASES
}

@test "rejects duplicates, including two dests naming one directory" {
    reject_all <<'CASES'
[{"name":"a","dest":"x"},{"name":"a","dest":"y"}]
[{"name":"a","dest":"x"},{"name":"b","dest":"x"}]
[{"name":"a","dest":"x"},{"name":"b","dest":"x/"}]
CASES
}
