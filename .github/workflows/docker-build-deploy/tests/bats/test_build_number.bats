#!/usr/bin/env bats
#
# jf-build-number overrides the JFrog build-info number. The release bundle
# splits <name>:<number> on `:` and joins it back as name/number, so the
# number is limited to the docker tag charset.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"

setup_file() {
    export SCRIPT_UNDER_TEST="${BATS_FILE_TMPDIR}/check.sh"
    yq -r '.jobs."parse-platforms".steps[] | select(.name == "Check jf-build-number") | .run' \
        "$WORKFLOW" > "$SCRIPT_UNDER_TEST"
}

check() {
    BUILD_NUMBER="$1" run bash "$SCRIPT_UNDER_TEST"
}

@test "jf-build-number accepts the docker tag charset" {
    check 42
    [ "$status" -eq 0 ]
    [ -z "$output" ]

    check 2.5.5-pr-166-50c3a4c
    [ "$status" -eq 0 ]

    check 2.5.5_20261030T091706Z
    [ "$status" -eq 0 ]
}

@test "jf-build-number rejects : and / and other characters" {
    local value
    for value in 'a:b' 'a/b' 'a b' 'a+b'; do
        check "$value"
        [ "$status" -eq 1 ]
        [[ $output == "::error::jf-build-number"* ]]
    done
}

@test "the check is skipped when jf-build-number is unset" {
    run yq -r '.jobs."parse-platforms".steps[] | select(.name == "Check jf-build-number") | .if' "$WORKFLOW"
    [ "$output" = "\${{ inputs.jf-build-number != '' }}" ]
}

@test "merge publishes build-info under jf-build-number, else the run number" {
    run yq -r '.jobs.merge.env.JFROG_CLI_BUILD_NUMBER' "$WORKFLOW"
    [ "$output" = '${{ inputs.jf-build-number || github.run_number }}' ]
}
