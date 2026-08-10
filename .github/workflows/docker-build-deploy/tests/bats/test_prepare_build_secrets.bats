#!/usr/bin/env bats
#
# What build-secrets-json writes into /tmp/docker-secrets, and what it must not.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"
STEP_NAME="Prepare build secrets"

setup_file() {
    export STEP_SOURCE="${BATS_FILE_TMPDIR}/step.sh"
    yq -r ".jobs.build.steps[] | select(.name == \"$STEP_NAME\") | .run" \
        "$WORKFLOW" > "$STEP_SOURCE"
}

setup() {
    SECRETS_DIR="${BATS_TEST_TMPDIR}/docker-secrets"
    STEP="${BATS_TEST_TMPDIR}/step.sh"
    sed "s#/tmp/docker-secrets#${SECRETS_DIR}#g" "$STEP_SOURCE" > "$STEP"
}

write_secrets() {
    OIDC_USER=u OIDC_TOKEN=t BUILD_SECRETS_JSON="$1" \
        GITHUB_ENV="${BATS_TEST_TMPDIR}/github_env" run bash "$STEP"
}

@test "the step this suite tests still exists in the workflow" {
    [ -s "$STEP" ]
}

@test "no caller-supplied value is interpolated into the script" {
    run grep -n 'secrets\.build-secrets-json' "$STEP_SOURCE"
    [ "$status" -ne 0 ]
}

@test "writes a single-line value verbatim" {
    write_secrets '{"token":"abc123"}'
    [ "$status" -eq 0 ]
    [ "$(cat "${SECRETS_DIR}/token")" = "abc123" ]
}

@test "writes a multi-line value unchanged" {
    local key
    key=$'-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nmDMEZ+abc\nxyz==\n-----END PGP PUBLIC KEY BLOCK-----'
    write_secrets "$(jq -nc --arg k "$key" '{gpg_public_key:$k}')"
    [ "$status" -eq 0 ]
    [ "$(cat "${SECRETS_DIR}/gpg_public_key")" = "$key" ]
}

@test "creates no file for anything the caller did not name" {
    local key
    key=$'line-one\nline-two\nline-three'
    write_secrets "$(jq -nc --arg k "$key" '{only:$k}')"
    [ "$status" -eq 0 ]
    [ "$(ls "$SECRETS_DIR" | grep -v jfrog_token | sort | tr '\n' ' ')" = "only " ]
}

@test "keeps entries separate when one value is multi-line" {
    local key
    key=$'first\nsecond'
    write_secrets "$(jq -nc --arg k "$key" '{multi:$k, plain:"single"}')"
    [ "$status" -eq 0 ]
    [ "$(cat "${SECRETS_DIR}/multi")" = "$key" ]
    [ "$(cat "${SECRETS_DIR}/plain")" = "single" ]
}

@test "appends no trailing newline" {
    write_secrets '{"token":"abc123"}'
    [ "$(wc -c < "${SECRETS_DIR}/token")" -eq 6 ]
}
