#!/usr/bin/env bats

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../../../../.."
    ACTION="${ROOT}/.github/actions/create-release-bundle/action.yaml"
    WORKFLOW="${ROOT}/.github/workflows/reusable_create-release-bundle.yaml"
}

@test "the action takes bundle-revision and returns bundle-version" {
    [ "$(yq -r '.inputs["bundle-revision"].default' "$ACTION")" = "" ]
    [ "$(yq -r '.outputs | has("bundle-version")' "$ACTION")" = "true" ]

    step="$(yq -r '.runs.steps[] | select(.id == "create")' "$ACTION")"
    [[ $step == *'BUNDLE_REVISION: ${{ inputs.bundle-revision }}'* ]]
    [[ $step == *'revision_arg=(--revision "$BUNDLE_REVISION")'* ]]
    [[ $step == *'"${revision_arg[@]}"'* ]]
}

@test "the workflow takes jf-bundle-revision and returns bundle-version" {
    [ "$(yq -r '.on.workflow_call.inputs["jf-bundle-revision"].default' "$WORKFLOW")" = "" ]
    [ "$(yq -r '.on.workflow_call.outputs | has("bundle-version")' "$WORKFLOW")" = "true" ]
    [ "$(yq -r '.jobs["create-release-bundle"].outputs | has("bundle-version")' "$WORKFLOW")" = "true" ]

    step="$(yq -r '.jobs["create-release-bundle"].steps[] | select(.id == "create")' "$WORKFLOW")"
    [[ $step == *'BUNDLE_REVISION: ${{ inputs.jf-bundle-revision }}'* ]]
    [[ $step == *'revision_arg=(--revision "$BUNDLE_REVISION")'* ]]
    [[ $step == *'"${revision_arg[@]}"'* ]]
}
