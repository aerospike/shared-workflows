#!/usr/bin/env bats

setup() {
    WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_promote-release-bundle.yaml"
    JOB='.jobs["promote-release-bundle"]'
    VERIFY_STEP="Verify the checkout is this workflow's commit"
}

step_names() {
    yq -r "${JOB}.steps[].name" "$WORKFLOW"
}

# Runs the verify step's script with an OIDC token whose job_workflow_sha claim is $1, against a
# checkout at a fresh commit. An empty $1 leaves the claim out.
run_verify() {
    local claim="$1" checkout="${BATS_TEST_TMPDIR}/checkout" payload
    git init -q "$checkout"
    git -C "$checkout" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    HEAD_SHA=$(git -C "$checkout" rev-parse HEAD)
    [[ $claim == HEAD ]] && claim="$HEAD_SHA"

    payload=$(jq -cn --arg s "$claim" 'if $s == "" then {} else {job_workflow_sha: $s} end | .sub = "repo:x/y:ref"' |
        base64 | tr -d '\n=' | tr '/+' '_-')
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    cat >"${BATS_TEST_TMPDIR}/bin/curl" <<STUB
#!/usr/bin/env bash
cat >/dev/null
jq -cn --arg v "e30.${payload}.sig" '{value: \$v}'
STUB
    chmod +x "${BATS_TEST_TMPDIR}/bin/curl"
    yq -r "${JOB}.steps[] | select(.name == \"${VERIFY_STEP}\") | .run" "$WORKFLOW" >"${BATS_TEST_TMPDIR}/verify.sh"
    PATH="${BATS_TEST_TMPDIR}/bin:$PATH" INPUT_CHECKOUT_PATH="$checkout" \
        ACTIONS_ID_TOKEN_REQUEST_URL=https://oidc.test ACTIONS_ID_TOKEN_REQUEST_TOKEN=req \
        run bash "${BATS_TEST_TMPDIR}/verify.sh"
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

@test "inputs reach the scripts through env, not expressions" {
    for name in "Promote Release Bundle" "$VERIFY_STEP"; do
        script="$(yq -r "${JOB}.steps[] | select(.name == \"${name}\") | .run" "$WORKFLOW")"
        [ -n "$script" ]
        [[ $script != *'${{'* ]]
    done
}

@test "only the job asks for attestations write" {
    expected="attestations=write,contents=read,id-token=write"
    [ "$(yq -r "${JOB}.permissions | to_entries | map(.key + \"=\" + .value) | sort | join(\",\")" "$WORKFLOW")" = "$expected" ]
    [ "$(yq -r '.permissions | to_entries | map(.key + "=" + .value) | sort | join(",")' "$WORKFLOW")" = "contents=read,id-token=write" ]
}

@test "promotions of one bundle to one stage run one at a time" {
    [ "$(yq -r "${JOB}.concurrency.group" "$WORKFLOW")" = 'promote-release-bundle-${{ inputs.jf-project }}-${{ inputs.jf-bundle-name }}-${{ inputs.target-stage }}' ]
    [ "$(yq -r "${JOB}.concurrency[\"cancel-in-progress\"]" "$WORKFLOW")" = "false" ]
}

@test "the checkout is verified after it is made and before the entrypoint runs" {
    names="$(step_names)"
    checkout_line=$(grep -n "^Checkout shared-workflows repository$" <<<"$names" | cut -d: -f1)
    verify_line=$(grep -nF "$VERIFY_STEP" <<<"$names" | cut -d: -f1)
    promote_line=$(grep -n "^Promote Release Bundle$" <<<"$names" | cut -d: -f1)
    ((checkout_line < verify_line && verify_line < promote_line))
}

@test "the verify step passes when the checkout is the workflow's commit" {
    run_verify HEAD
    [ "$status" -eq 0 ]
}

@test "the verify step fails when the checkout is another commit" {
    run_verify 0123456789abcdef0123456789abcdef01234567
    [ "$status" -eq 1 ]
    [[ $output == *"::error::The shared-workflows checkout (${HEAD_SHA}) is not the commit this workflow runs from (0123456789abcdef0123456789abcdef01234567)"* ]]
}

@test "the verify step fails when the token has no job_workflow_sha" {
    run_verify ""
    [ "$status" -eq 1 ]
    [[ $output == *"(unknown)"* ]]
}
