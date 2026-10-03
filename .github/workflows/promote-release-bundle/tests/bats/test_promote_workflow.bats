#!/usr/bin/env bats

setup() {
    WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_promote-release-bundle.yaml"
    JOB='.jobs["promote-release-bundle"]'
}

@test "the promotion job is attached to the gh-environment input" {
    [ "$(yq -r "${JOB}.environment" "$WORKFLOW")" = '${{ inputs.gh-environment }}' ]
}

@test "the entrypoint runs from the shared-workflows checkout at gh-workflows-ref" {
    checkout="$(yq -r "${JOB}.steps[] | select(.uses == \"actions/checkout@*\")" "$WORKFLOW")"
    [[ $checkout == *"repository: aerospike/shared-workflows"* ]]
    [[ $checkout == *'ref: ${{ inputs.gh-workflows-ref }}'* ]]
    [ "$(yq -r "[${JOB}.steps[] | select(.uses == \"./*\")] | length" "$WORKFLOW")" = "0" ]
}

@test "inputs reach the promote script through env, not expressions" {
    script="$(yq -r "${JOB}.steps[] | select(.name == \"Promote Release Bundle\") | .run" "$WORKFLOW")"
    [[ $script != *'${{'* ]]
}

@test "the job asks for no permission beyond contents read and id-token write" {
    [ "$(yq -r "${JOB}.permissions | to_entries | map(.key + \"=\" + .value) | sort | join(\",\")" "$WORKFLOW")" = "contents=read,id-token=write" ]
}
