#!/usr/bin/env bats
#
# container-destination is optional. An empty value does not call jf.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"
STEP_NAME="Set container_destination"

setup_file() {
    export SCRIPT_UNDER_TEST="${BATS_FILE_TMPDIR}/set-container-destination.sh"
    yq -r ".jobs.merge.steps[] | select(.name == \"$STEP_NAME\") | .run" \
        "$WORKFLOW" >"$SCRIPT_UNDER_TEST"
}

setup() {
    export JF_LOG="${BATS_TEST_TMPDIR}/jf.log"
    : >"$JF_LOG"
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    cat >"${BATS_TEST_TMPDIR}/bin/jf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$JF_LOG"
EOF
    chmod +x "${BATS_TEST_TMPDIR}/bin/jf"
    export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

run_set() {
    CONTAINER_DESTINATION="$1" \
        IMMUTABLE_TAG="${2:-artifact.aerospike.io/database-docker-dev-local/test-image:7.0.0_20251202T021054Z}" \
        run bash "$SCRIPT_UNDER_TEST"
}

@test "the step this suite tests still exists in the workflow" {
    [ -s "$SCRIPT_UNDER_TEST" ]
}

@test "container-destination is optional and empty by default" {
    local required default_value
    required="$(yq -r '.on.workflow_call.inputs."container-destination".required' "$WORKFLOW")"
    default_value="$(yq -r '.on.workflow_call.inputs."container-destination".default' "$WORKFLOW")"
    [ "$required" = "false" ]
    [ "$default_value" = "" ]
}

@test "the property step runs on merge only after a push, before build-info" {
    local names job
    job="$(yq -r '.jobs | to_entries[]
        | select(.value.steps[]?.name == "Set container_destination")
        | .key' "$WORKFLOW")"
    [ "$job" = "merge" ]
    names="$(yq -r '.jobs.merge.steps[].name' "$WORKFLOW")"
    awk '
        $0 == "Create multi-platform manifest" { seen_manifest = 1 }
        $0 == "Set container_destination" { if (!seen_manifest) exit 1; seen_prop = 1 }
        $0 == "Create build info for docker image" { if (!seen_prop) exit 1; found = 1 }
        END { exit !found }
    ' <<<"$names"

    local condition
    condition="$(yq -r '.jobs.merge.steps[] | select(.name == "Set container_destination") | .if' "$WORKFLOW")"
    [[ "$condition" == *"inputs.push"* ]]
    [[ "$condition" == *"inputs.container-destination"* ]]
}

@test "an empty destination does not call jf" {
    run_set ""
    [ "$status" -eq 0 ]
    [ ! -s "$JF_LOG" ]
}

@test "a blank destination does not call jf" {
    run_set " , "
    [ "$status" -eq 0 ]
    [ ! -s "$JF_LOG" ]
}

@test "one destination is a single property value on the immutable tag" {
    run_set "quayio"
    [ "$status" -eq 0 ]
    [ "$(cat "$JF_LOG")" = "rt set-props database-docker-dev-local/test-image/7.0.0_20251202T021054Z/*manifest.json container_destination=quayio" ]
}

@test "several destinations stay in order" {
    run_set " quayio, opnshift "
    [ "$status" -eq 0 ]
    [ "$(cat "$JF_LOG")" = "rt set-props database-docker-dev-local/test-image/7.0.0_20251202T021054Z/*manifest.json container_destination=quayio,opnshift" ]
}

@test "a value that would add another property is rejected" {
    run_set "quayio;dockerio"
    [ "$status" -ne 0 ]
    [ ! -s "$JF_LOG" ]
}
