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

@test "the job can write attestations" {
    result=$(query "d['jobs']['promote-release-bundle']['permissions'].get('attestations')")
    [ "$result" = "write" ]
}

@test "the record is verified by digest before it is attested" {
    fetch=$(query "[s for s in d['jobs']['promote-release-bundle']['steps'] if s.get('id') == 'record']")
    [[ $fetch == *"sha256sum"* ]]
    [[ $fetch == *"exit 1"* ]]
}

@test "the attestation is SHA-pinned and carries the supersede predicate type" {
    attest=$(query "[s for s in d['jobs']['promote-release-bundle']['steps'] if 'actions/attest' in str(s.get('uses',''))]")
    [[ $attest =~ actions/attest@[0-9a-f]{40} ]]
    [[ $attest == *"https://aerospike.com/schemas/supersede/v1"* ]]
}
