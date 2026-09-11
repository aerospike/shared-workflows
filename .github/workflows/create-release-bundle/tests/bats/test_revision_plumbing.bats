#!/usr/bin/env bats

setup() {
    ROOT="${BATS_TEST_DIRNAME}/../../../../.."
    ACTION="${ROOT}/.github/actions/create-release-bundle/action.yaml"
    WORKFLOW="${ROOT}/.github/workflows/reusable_create-release-bundle.yaml"
}

@test "the action takes bundle-revision and returns bundle-version" {
    run python3 -c "
import yaml
d = yaml.safe_load(open('$ACTION'))
assert 'bundle-revision' in d['inputs'], 'input missing'
assert d['inputs']['bundle-revision'].get('default') == '', 'default is not empty'
assert 'bundle-version' in d.get('outputs', {}), 'output missing'
step = d['runs']['steps'][0]['run']
assert '--revision' in step, 'revision not passed to the entrypoint'
assert 'github.run_id' in step, 'auto does not resolve to the run'
"
    [ "$status" -eq 0 ]
}

@test "the workflow takes bundle-revision and returns bundle-version" {
    run python3 -c "
import yaml
d = yaml.safe_load(open('$WORKFLOW'))
wc = d[True]['workflow_call']
assert 'bundle-revision' in wc['inputs'], 'input missing'
assert wc['inputs']['bundle-revision'].get('default') == '', 'default is not empty'
assert 'bundle-version' in wc.get('outputs', {}), 'workflow output missing'
job = d['jobs']['create-release-bundle']
assert 'bundle-version' in job.get('outputs', {}), 'job output missing'
step = [s for s in job['steps'] if s.get('id') == 'create'][0]['run']
assert '--revision' in step, 'revision not passed to the entrypoint'
assert 'github.run_id' in step, 'auto does not resolve to the run'
"
    [ "$status" -eq 0 ]
}
