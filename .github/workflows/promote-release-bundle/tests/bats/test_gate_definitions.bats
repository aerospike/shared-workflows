#!/usr/bin/env bats

setup() {
    GATES="${BATS_TEST_DIRNAME}/../../../../gates"
    SCHEMA="${BATS_TEST_DIRNAME}/../../gate-definition.schema.json"
    STAGES=(DEV TEST STAGE PREVIEW INTERNAL PROD)
}

check_gates() {
    local dir="$1" stage file name problems=""
    for stage in "${STAGES[@]}"; do
        [[ -f ${dir}/${stage}.json ]] || problems+="${stage}.json is missing"$'\n'
    done
    for file in "$dir"/*; do
        name=$(basename "$file")
        [[ " ${STAGES[*]} " == *" ${name%.json} "* && $name == *.json ]] ||
            problems+="${name} is not a gate definition"$'\n'
    done
    if [[ -z $problems ]]; then
        problems=$(check-jsonschema --schemafile "$SCHEMA" "$dir"/*.json 2>&1) && problems=""
    fi
    if [[ -z $problems ]]; then
        for file in "$dir"/*.json; do
            problems+=$(jq -r --arg name "$(basename "$file")" \
                '[.requires[].id] | group_by(.)[] | select(length > 1) | "\($name): requirement id \(.[0]) is repeated\n"' "$file")
        done
    fi
    if [[ -n $problems ]]; then
        printf '%s\n' "$problems"
        return 1
    fi
}

expect_rejected() {
    local stage="$1" filter="$2" expected="$3" copy="${BATS_TEST_TMPDIR}/gates"
    rm -rf "$copy"
    cp -R "$GATES" "$copy"
    jq --tab "$filter" "${GATES}/${stage}.json" >"${copy}/${stage}.json"
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
    [[ $output == *"TEST.json"* ]]
}

@test "a definition that breaks the schema is rejected" {
    expect_rejected TEST '.schema = 2' 'TEST.json::$.schema'
    expect_rejected TEST '.mode = "block"' 'TEST.json::$.mode'
    expect_rejected TEST '.stage = "TEST"' "'stage' was unexpected"
    expect_rejected TEST '.requires[0].check = "scan"' 'TEST.json::$.requires[0].check'
}

@test "a repeated requirement id is rejected" {
    expect_rejected TEST '.requires[1].id = .requires[0].id' 'TEST.json: requirement id security-check is repeated'
}
