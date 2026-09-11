#!/usr/bin/env bats

setup() {
    WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_promote-release-bundle.yaml"
}

query() {
    python3 -c "
import yaml, sys
d = yaml.safe_load(open('$WORKFLOW'))
print($1)
"
}

@test "the promotion job is attached to the gh-environment input" {
    result=$(query "d['jobs']['promote-release-bundle'].get('environment')")
    [ "$result" = '${{ inputs.gh-environment }}' ]
}

@test "supersede is refused without a gh-environment" {
    result=$(query "[s for s in d['jobs']['promote-release-bundle']['steps'] if s.get('if') == 'inputs.supersede']")
    [[ $result == *"gh-environment"* ]]
    [[ $result == *"exit 1"* ]]
}

@test "supersede defaults to false" {
    result=$(query "d[True]['workflow_call']['inputs']['supersede']['default']")
    [ "$result" = "False" ]
}

@test "the entrypoint is run from the pinned shared-workflows checkout" {
    steps=$(query "d['jobs']['promote-release-bundle']['steps']")
    [[ $steps == *"gh-checkout-path"* ]]
    [[ $steps != *"uses': './"* ]]

    checkout=$(query "[s for s in d['jobs']['promote-release-bundle']['steps'] if 'checkout' in str(s.get('uses',''))]")
    [[ $checkout == *"gh-workflows-ref"* ]]
    [[ $checkout == *"aerospike/shared-workflows"* ]]
}
