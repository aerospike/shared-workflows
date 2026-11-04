#!/usr/bin/env bats
#
# What the build job writes into /tmp/docker-secrets.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"

setup_file() {
    export STEP_SOURCE="${BATS_FILE_TMPDIR}/step.sh"
    yq -r '.jobs.build.steps[] | select(.name == "Prepare build secrets") | .run' \
        "$WORKFLOW" > "$STEP_SOURCE"
}

setup() {
    SECRETS_DIR="${BATS_TEST_TMPDIR}/docker-secrets"
    STEP="${BATS_TEST_TMPDIR}/step.sh"
    sed "s#/tmp/docker-secrets#${SECRETS_DIR}#g" "$STEP_SOURCE" > "$STEP"
}

# write_secrets <build-secrets-json> [jf-go-repo]
write_secrets() {
    OIDC_USER='ci@example.com' OIDC_TOKEN='t:k/+' \
        JF_GO_REPO="${2:-}" JF_REGISTRY_BASE=artifact.aerospike.io \
        BUILD_SECRETS_JSON="$1" \
        GITHUB_ENV="${BATS_TEST_TMPDIR}/github_env" run bash "$STEP"
}

@test "writes each value byte-for-byte to its own file, and nothing the caller did not name" {
    local key=$'-----BEGIN PGP PUBLIC KEY BLOCK-----\n\nmDMEZ+abc\nxyz==\n-----END PGP PUBLIC KEY BLOCK-----'
    write_secrets "$(jq -nc --arg k "$key" '{gpg_public_key: $k, token: "abc123"}')" platforms-go-virtual
    [ "$status" -eq 0 ]
    cmp "${SECRETS_DIR}/gpg_public_key" <(printf '%s' "$key")
    cmp "${SECRETS_DIR}/token" <(printf '%s' abc123)
    cmp "${SECRETS_DIR}/jfrog_token" <(printf '%s' 't:k/+')
    cmp "${SECRETS_DIR}/goproxy" \
        <(printf '%s' 'https://ci%40example.com:t%3Ak%2F%2B@artifact.aerospike.io/artifactory/api/go/platforms-go-virtual')
    [ "$(ls "$SECRETS_DIR" | tr '\n' ' ')" = "goproxy gpg_public_key jfrog_token token " ]
}

@test "rejects a key that is not a plain filename" {
    local k
    for k in ../escape a/b .hidden 'a b'; do
        write_secrets "$(jq -nc --arg k "$k" '{($k): "v"}')"
        if [ "$status" -eq 0 ]; then
            echo "accepted key: $k"
            return 1
        fi
    done
    [ ! -e "$(dirname "$SECRETS_DIR")/escape" ]
}
