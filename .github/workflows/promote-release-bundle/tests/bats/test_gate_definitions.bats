#!/usr/bin/env bats

setup() {
    GATES="${BATS_TEST_DIRNAME}/../../../../gates"
    VALIDATE="${BATS_TEST_DIRNAME}/../../gate-definition.jq"
    STAGES=(DEV TEST STAGE PREVIEW INTERNAL PROD)
}

check_gates() {
    local dir="$1" stage file name found problems=""
    for stage in "${STAGES[@]}"; do
        file="${dir}/${stage}.json"
        if [[ ! -f $file ]]; then
            problems+="${stage}.json is missing"$'\n'
            continue
        fi
        found=$(jq -r --arg stage "$stage" -f "$VALIDATE" "$file" 2>&1 | sed "s/^/${stage}.json: /")
        [[ -z $found ]] || problems+="${found}"$'\n'
    done
    for file in "$dir"/*; do
        name=$(basename "$file" .json)
        if [[ " ${STAGES[*]} " != *" ${name} "* || $file != *.json ]]; then
            problems+="$(basename "$file") is not a gate definition"$'\n'
        fi
    done
    if [[ -n $problems ]]; then
        printf '%s\n' "$problems"
        return 1
    fi
}

expect_rejected() {
    local stage="$1" filter="$2" expected="$3" copy="${BATS_TEST_TMPDIR}/gates"
    rm -rf "$copy"
    cp -R "$GATES" "$copy"
    jq "$filter" "${GATES}/${stage}.json" >"${copy}/${stage}.json"
    run check_gates "$copy"
    if [[ $status -eq 0 || $output != *"$expected"* ]]; then
        echo "filter ${filter} on ${stage}.json: status ${status}, expected output to contain: ${expected}"
        echo "$output"
        return 1
    fi
}

@test "the gate definitions are valid" {
    run check_gates "$GATES"
    echo "$output"
    [ "$status" -eq 0 ]
}

@test "a missing or unexpected definition file is rejected" {
    local copy="${BATS_TEST_TMPDIR}/gates"
    cp -R "$GATES" "$copy"
    rm "${copy}/PROD.json"
    echo '{}' >"${copy}/QA.json"
    run check_gates "$copy"
    [ "$status" -eq 1 ]
    [[ $output == *"PROD.json is missing"* ]]
    [[ $output == *"QA.json is not a gate definition"* ]]
}

@test "a definition that is not JSON is rejected" {
    local copy="${BATS_TEST_TMPDIR}/gates"
    cp -R "$GATES" "$copy"
    echo '{"schema": 1,' >"${copy}/TEST.json"
    run check_gates "$copy"
    [ "$status" -eq 1 ]
    [[ $output == *"TEST.json: "* ]]
}

@test "a definition with a bad schema, stage, page or mode is rejected" {
    expect_rejected TEST '.schema = 2' 'schema is not 1'
    expect_rejected TEST 'del(.schema)' 'schema is not 1'
    expect_rejected TEST '.stage = "STAGE"' 'stage is "STAGE", expected TEST'
    expect_rejected TEST '.page = "http://example.com"' 'page is not an https URL'
    expect_rejected TEST '.mode = "block"' 'mode "block" is not warn or enforce'
    expect_rejected TEST 'del(.mode)' 'mode null is not warn or enforce'
    expect_rejected TEST '.projects = []' 'projects is not an object'
    expect_rejected TEST '.projects.test = {mode: "on"}' 'project test: mode "on" is not warn or enforce'
    expect_rejected TEST '.projects.test = "enforce"' 'project test: mode null is not warn or enforce'
}

@test "a requirement without an id, check or required flag is rejected" {
    expect_rejected TEST '.requires = {}' 'requires is not an array'
    expect_rejected TEST 'del(.requires[0].id)' 'requirement 0: has no id'
    expect_rejected TEST '.requires[0].id = ""' 'requirement 0: has no id'
    expect_rejected TEST '.requires[1].id = .requires[0].id' 'is repeated'
    expect_rejected TEST 'del(.requires[0].check)' 'requirement 0: has no check'
    expect_rejected TEST '.requires[0].check = 1' 'requirement 0: check is not a string or null'
    expect_rejected TEST '.requires[0].required = "yes"' 'requirement 0: required is not true or false'
    expect_rejected TEST '.requires[0] = "security-check"' 'requirement 0: is not an object'
}
