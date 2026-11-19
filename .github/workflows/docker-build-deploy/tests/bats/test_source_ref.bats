#!/usr/bin/env bats
#
# source-ref / source-sha name the ref the image is built from, which is not
# the ref the run was dispatched from when a workflow on the default branch
# builds another branch.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"

# bats-core has no assertion library, so a table row that fails has to name
# itself.
fail() {
    echo "$1" >&2
    return 1
}

setup_file() {
    export CHECK_INPUTS="${BATS_FILE_TMPDIR}/check-inputs.sh"
    export CHECKOUT_COMMIT="${BATS_FILE_TMPDIR}/checkout-commit.sh"
    yq -r '.jobs."parse-platforms".steps[] | select(.name == "Check source ref inputs") | .run' \
        "$WORKFLOW" > "$CHECK_INPUTS"
    yq -r '.jobs.merge.steps[] | select(.name == "Check out the built commit") | .run' \
        "$WORKFLOW" > "$CHECKOUT_COMMIT"
    export PREPARE_LABELS="${BATS_FILE_TMPDIR}/prepare-labels.sh"
    yq -r '.jobs.build.steps[] | select(.name == "Prepare build args/labels") | .run' \
        "$WORKFLOW" > "$PREPARE_LABELS"
}

# origin holds commit A on main and commit B on hotfix/8.0.1. Each work tree is
# a shallow clone of main, so B is absent until the step fetches it.
make_origin() {
    ORIGIN="${BATS_TEST_TMPDIR}/origin"
    git init -q -b main "$ORIGIN"
    git -C "$ORIGIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m A
    git -C "$ORIGIN" checkout -q -b hotfix/8.0.1
    git -C "$ORIGIN" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m B
    git -C "$ORIGIN" checkout -q main
    git -C "$ORIGIN" config uploadpack.allowAnySHA1InWant true
    SHA_B="$(git -C "$ORIGIN" rev-parse hotfix/8.0.1)"
}

clone_main() {
    git clone -q --depth 1 --branch main "file://${ORIGIN}" "$1"
}

# "-" stands for an unset input; no value under test starts with one.
@test "source-sha is accepted only as a commit id on a named ref" {
    local ref sha expected
    while read -r ref sha expected; do
        SOURCE_REF="${ref#-}" SOURCE_SHA="${sha#-}" run bash "$CHECK_INPUTS"
        [ "$status" -eq "$expected" ] || fail "ref=${ref} sha=${sha}: status ${status}"
        if [ "$expected" -ne 0 ]; then
            [[ $output == "::error::"* ]] || fail "ref=${ref} sha=${sha}: ${output}"
        fi
    done <<<"- - 0
hotfix/8.0.1 - 0
hotfix/8.0.1 0123456789abcdef0123456789abcdef01234567 0
- 0123456789abcdef0123456789abcdef01234567 1
hotfix/8.0.1 hotfix/8.0.1 1
hotfix/8.0.1 0123abc 1
hotfix/8.0.1 0123456789ABCDEF0123456789ABCDEF01234567 1"
}

@test "the work tree ends on the built commit, named by the built ref" {
    make_origin
    local ref work i=0
    for ref in hotfix/8.0.1 refs/heads/hotfix/8.0.1; do
        work="${BATS_TEST_TMPDIR}/work$((i++))"
        clone_main "$work"
        cd "$work"
        SOURCE_REF="$ref" SOURCE_SHA="$SHA_B" run bash "$CHECKOUT_COMMIT"
        [ "$status" -eq 0 ] || fail "ref=${ref}: ${output}"
        [ "$(git -C "$work" rev-parse HEAD)" = "$SHA_B" ] || fail "ref=${ref}: wrong commit"
        [ "$(git -C "$work" branch --show-current)" = hotfix/8.0.1 ] || fail "ref=${ref}: wrong branch"
    done
}

@test "the revision label names the commit in the work tree" {
    make_origin
    local work="${BATS_TEST_TMPDIR}/work"
    clone_main "$work"
    cd "$work"
    GITHUB_ENV="${BATS_TEST_TMPDIR}/github-env" TITLE=image APP_VERSION=1.0.0 \
        SOURCE_URL=https://example.com/o/r LABELS_JSON={} BUILD_ARGS_JSON={} \
        run bash "$PREPARE_LABELS"
    [ "$status" -eq 0 ] || fail "$output"
    grep -qx "org.opencontainers.image.revision=$(git -C "$work" rev-parse HEAD)" \
        "${BATS_TEST_TMPDIR}/github-env"
}

@test "the checkouts follow the inputs" {
    local build_ref merge_ref
    build_ref="$(yq -r '.jobs.build.steps[] | select((.uses // "") | test("actions/checkout")) | .with.ref' "$WORKFLOW")"
    merge_ref="$(yq -r '.jobs.merge.steps[] | select((.uses // "") | test("actions/checkout")) | .with.ref' "$WORKFLOW")"

    # The build job wants the commit's tree, so the exact commit wins there.
    # The merge job wants the branch name, which only a ref carries.
    [ "$build_ref" = '${{ inputs.source-sha || inputs.source-ref }}' ]
    [ "$merge_ref" = '${{ inputs.source-ref }}' ]
}
