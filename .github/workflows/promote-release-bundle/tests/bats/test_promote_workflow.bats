#!/usr/bin/env bats

setup() {
    WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_promote-release-bundle.yaml"
    JOB='.jobs["promote-release-bundle"]'
    VERIFY_STEP="Verify the checkout is this workflow's commit"
}

# Runs the verify step with an OIDC token whose job_workflow_sha claim is $1 ("HEAD" for the
# checkout's own commit).
run_verify() {
    local claim="$1" checkout="${BATS_TEST_TMPDIR}/checkout" payload
    git init -q "$checkout"
    git -C "$checkout" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
    [[ $claim == HEAD ]] && claim=$(git -C "$checkout" rev-parse HEAD)

    payload=$(jq -cn --arg s "$claim" '{job_workflow_sha: $s}' | base64 | tr -d '\n=' | tr '/+' '_-')
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

@test "inputs reach the scripts through env, not expressions" {
    for name in "Promote Release Bundle" "$VERIFY_STEP"; do
        script="$(yq -r "${JOB}.steps[] | select(.name == \"${name}\") | .run" "$WORKFLOW")"
        [ -n "$script" ]
        [[ $script != *'${{'* ]]
    done
}

@test "the verify step passes when the checkout is the workflow's commit" {
    run_verify HEAD
    [ "$status" -eq 0 ]
}

@test "the verify step fails when the checkout is another commit" {
    run_verify 0123456789abcdef0123456789abcdef01234567
    [ "$status" -eq 1 ]
    [[ $output == *"is not the commit this workflow runs from"* ]]
}
