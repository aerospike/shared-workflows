#!/usr/bin/env bats
#
# jf-registry is deprecated. The BuildKit pull and build-info always use the
# derived registry, so any other value fails before a leg starts.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"
DERIVED=artifact.aerospike.io/database-container-dev-local

setup_file() {
    export SCRIPT_UNDER_TEST="${BATS_FILE_TMPDIR}/check.sh"
    yq -r '.jobs."parse-platforms".steps[] | select(.name == "Check registry inputs") | .run' \
        "$WORKFLOW" > "$SCRIPT_UNDER_TEST"
}

check() {
    JF_REGISTRY="$1" DERIVED_REGISTRY="$DERIVED" run bash "$SCRIPT_UNDER_TEST"
}

@test "jf-registry must be unset or equal the registry the jobs push to" {
    local derived_expr
    derived_expr="$(yq -r '.jobs."parse-platforms".steps[] | select(.name == "Check registry inputs") | .env.DERIVED_REGISTRY' "$WORKFLOW")"
    [ "$(yq -r '.jobs.build.env.REGISTRY' "$WORKFLOW")" = "$derived_expr" ]
    [ "$(yq -r '.jobs.merge.env.REGISTRY' "$WORKFLOW")" = "$derived_expr" ]

    check ""
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    check "$DERIVED"
    [ "$status" -eq 0 ]
    [[ $output == "::warning::jf-registry is deprecated"* ]]

    check aerospike.jfrog.io/database-container-dev-local
    [ "$status" -eq 1 ]
    [[ $output == "::error::"* ]]

    check artifact.aerospike.io/database-docker-dev-local
    [ "$status" -eq 1 ]
}
