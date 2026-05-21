#!/usr/bin/env bats
# Tests for .github/workflows/execute-build/parse-build-env.sh

setup() {
    GIT_ROOT="$(git rev-parse --show-toplevel)"
    SCRIPT="$GIT_ROOT/.github/workflows/execute-build/parse-build-env.sh"
}

@test "empty BUILD_ENV emits nothing and exits 0" {
    BUILD_ENV="" run "$SCRIPT"
    [[ $status -eq 0 ]]
    [[ -z $output ]]
}

@test "unset BUILD_ENV emits nothing and exits 0" {
    unset BUILD_ENV
    run "$SCRIPT"
    [[ $status -eq 0 ]]
    [[ -z $output ]]
}

@test "single KV emits one line" {
    BUILD_ENV="VERSION=1.2.3" run "$SCRIPT"
    [[ $status -eq 0 ]]
    [[ $output == "VERSION=1.2.3" ]]
}

@test "multi-KV emits one line per pair in order" {
    BUILD_ENV="A=1;B=2;C=3" run "$SCRIPT"
    [[ $status -eq 0 ]]
    [[ ${lines[0]} == "A=1" ]]
    [[ ${lines[1]} == "B=2" ]]
    [[ ${lines[2]} == "C=3" ]]
}

@test "backslash escape \\; produces literal semicolon in value" {
    # shellcheck disable=SC1003
    BUILD_ENV='A=a\;b;B=plain' run "$SCRIPT"
    [[ $status -eq 0 ]]
    [[ ${lines[0]} == "A=a;b" ]]
    [[ ${lines[1]} == "B=plain" ]]
}

@test "backslash escape \\\\ produces literal backslash in value" {
    # shellcheck disable=SC1003
    BUILD_ENV='PATH_LIKE=a\\b' run "$SCRIPT"
    [[ $status -eq 0 ]]
    [[ ${lines[0]} == 'PATH_LIKE=a\b' ]]
}

@test "value containing = uses only first = as split point" {
    BUILD_ENV="URL=http://x?a=b&c=d" run "$SCRIPT"
    [[ $status -eq 0 ]]
    [[ $output == "URL=http://x?a=b&c=d" ]]
}

@test "pair missing = exits non-zero with KEY=VALUE error" {
    BUILD_ENV="NOEQUALS" run "$SCRIPT"
    [[ $status -ne 0 ]]
    [[ $output == *"build-env entries must be KEY=VALUE"* ]]
}

@test "key starting with digit exits non-zero with invalid name error" {
    BUILD_ENV="1FOO=x" run "$SCRIPT"
    [[ $status -ne 0 ]]
    [[ $output == *"invalid env var name"* ]]
}

@test "empty key (leading =) exits non-zero" {
    BUILD_ENV="=value" run "$SCRIPT"
    [[ $status -ne 0 ]]
    [[ $output == *"invalid env var name"* ]]
}

@test "value containing semicolon-inside-quotes is still split (regression: parser is content-agnostic)" {
    # The parser does not know about JSON or quoting. A raw ';' splits, period.
    # This documents why MATRIX_JSON must travel via matrix-json-data (a separate
    # input), not via build-env: a JSON value like {"k":"a;b"} would otherwise be
    # cut in half by this parser.
    BUILD_ENV='JSON={"k":"a;b"}' run "$SCRIPT"
    [[ $status -ne 0 ]]
}

@test "value containing JSON without semicolons parses cleanly" {
    BUILD_ENV='JSON={"k":"v","n":1}' run "$SCRIPT"
    [[ $status -eq 0 ]]
    [[ $output == 'JSON={"k":"v","n":1}' ]]
}

@test "empty pairs from trailing or doubled semicolons are skipped" {
    BUILD_ENV="A=1;;B=2;" run "$SCRIPT"
    [[ $status -eq 0 ]]
    [[ ${lines[0]} == "A=1" ]]
    [[ ${lines[1]} == "B=2" ]]
    [[ ${#lines[@]} -eq 2 ]]
}

@test "merged top + matrix build-env: later duplicate key wins when sourced (merge contract)" {
    # Documents the orchestrator merge contract: reusable_artifacts-cicd.yaml
    # concatenates top-level build-env with matrix-level as 'top;matrix' so
    # matrix appears AFTER top. The parser emits both in order; when the
    # consuming step sources them into the environment, the second assignment
    # to a duplicate key overwrites the first. This is how matrix-level
    # entries shadow top-level on conflict.
    BUILD_ENV="A=1;B=2;B=99;C=3" run "$SCRIPT"
    [[ $status -eq 0 ]]
    [[ ${lines[0]} == "A=1" ]]
    [[ ${lines[1]} == "B=2" ]]
    [[ ${lines[2]} == "B=99" ]]
    [[ ${lines[3]} == "C=3" ]]
}

