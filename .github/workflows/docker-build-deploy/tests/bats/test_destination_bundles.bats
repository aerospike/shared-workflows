#!/usr/bin/env bats
#
# Quay and OpenShift test bundles. The list is the plan the dispatch workflow
# builds. A version that already exists stops the run.

SCRIPT="${BATS_TEST_DIRNAME}/../../create-test-destination-bundles.sh"
WORKFLOW="${BATS_TEST_DIRNAME}/../../../test_docker-destination-bundles.yaml"

SEARCH_CMD="release-bundle-search versions test-docker-release --project=test --format=json"

setup() {
    export JF_LOG="${BATS_TEST_TMPDIR}/jf.log"
    export JF_RESPONSE="${BATS_TEST_TMPDIR}/response.json"
    : >"$JF_LOG"
    mkdir -p "${BATS_TEST_TMPDIR}/bin"
    cat >"${BATS_TEST_TMPDIR}/bin/jf" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$JF_LOG"
if [[ ${1-} == release-bundle-search ]]; then
    cat "$JF_RESPONSE"
fi
EOF
    chmod +x "${BATS_TEST_TMPDIR}/bin/jf"
    export PATH="${BATS_TEST_TMPDIR}/bin:${PATH}"
}

job_lines() {
    local pattern="$1"
    PATTERN="$pattern" yq -r '
        .jobs | to_entries[]
        | select((.value.uses // "") | test(strenv(PATTERN)))
        | .key
    ' "$WORKFLOW"
}

needs_of() {
    JOB="$1" yq -o=json '.jobs[strenv(JOB)].needs' "$WORKFLOW" |
        jq -r 'if type == "array" then .[] elif type == "string" then . else empty end'
}

job_get() {
    JOB="$1" yq -r ".jobs[strenv(JOB)].$2" "$WORKFLOW"
}

@test "dry run prints the bundle list and does not call jf" {
    run bash "$SCRIPT" --dry-run
    [ "$status" -eq 0 ]
    [ ! -s "$JF_LOG" ]

    local version image count destination expected=""
    while IFS=$'\t' read -r version image count destination; do
        expected+="${version} ${image} ${count} ${destination}"$'\n'
    done <<'EOF'
quay-1	test-image	1	quay
openshift-1	test-image	1	openshift
quay-openshift-1	test-image	1	quay,openshift
openshift-2	test-image	2	openshift
EOF
    [ "$output" = "${expected%$'\n'}" ]
}

@test "an existing version stops the run and other versions stay" {
    local versions status_want version
    while IFS=$'\t' read -r versions status_want; do
        if [[ $versions == NONE ]]; then
            versions=""
        fi
        if [[ $versions == INVALID ]]; then
            printf '%s\n' 'not-json' >"$JF_RESPONSE"
        else
            jq -n --arg versions "$versions" '
                {
                    release_bundles: (
                        if $versions == "" then []
                        else ($versions | split(",") | map({
                            release_bundle_name: "test-docker-release",
                            release_bundle_version: .
                        }))
                        end
                    )
                }
            ' >"$JF_RESPONSE"
        fi
        : >"$JF_LOG"
        run bash "$SCRIPT"
        [ "$status" -eq "$status_want" ]
        [ "$(cat "$JF_LOG")" = "$SEARCH_CMD" ]
        [[ $output != *7.8.12* ]]
        [[ $output != *[Dd]elet* ]]
        if [[ $status_want -eq 0 ]]; then
            [ "$output" = "No test-docker-release version from this list exists in test-release-bundles-v2." ]
        elif [[ $versions == INVALID ]]; then
            [[ $output == *"unexpected release bundle search response for test-docker-release"* ]]
        else
            while IFS= read -r version; do
                [[ $version == 7.8.12 ]] && continue
                [[ $output == *"test-docker-release@${version} already exists in test-release-bundles-v2. Not creating another copy."* ]]
            done < <(printf '%s\n' "$versions" | tr ',' '\n')
        fi
    done <<'EOF'
NONE	0
7.8.12	0
quay-1	1
openshift-2	1
quay-1,openshift-1,quay-openshift-1,openshift-2	1
7.8.12,quay-1	1
INVALID	1
EOF
}

@test "the workflow builds and bundles the script list" {
    [ "$(yq -r '.on | has("workflow_dispatch")' "$WORKFLOW")" = "true" ]
    [ "$(yq -r '.on | has("pull_request")' "$WORKFLOW")" = "false" ]
    [ "$(yq -r '.on | has("push")' "$WORKFLOW")" = "false" ]
    [ -z "$(yq -r '.. | select(tag == "!!str") | select(test("delete-release-bundle|release-bundle-delete"))' "$WORKFLOW")" ]

    local guard="" job
    while IFS= read -r job; do
        [[ -n $job ]] || continue
        [ -z "$guard" ]
        guard=$job
    done < <(yq -r '
        .jobs | to_entries[]
        | select(.value.steps[]?.run == ".github/workflows/docker-build-deploy/create-test-destination-bundles.sh")
        | .key
    ' "$WORKFLOW")
    [ -n "$guard" ]
    local runs
    runs="$(job_get "$guard" 'steps[].run // ""')"
    [[ $runs == *create-test-destination-bundles.sh* ]]
    [[ $runs != *--dry-run* ]]

    local version image count destination bundle_job need
    local line_count=0
    local seen_builds="" app_versions="" build_names=""
    while IFS=' ' read -r version image count destination; do
        line_count=$((line_count + 1))
        bundle_job="$(job_lines "reusable_create-release-bundle\\.yaml" | while IFS= read -r job; do
            if [ "$(job_get "$job" 'with.version')" = "$version" ]; then
                printf '%s\n' "$job"
            fi
        done)"
        [ "$(printf '%s\n' "$bundle_job" | grep -c . || true)" -eq 1 ]
        [ "$(job_get "$bundle_job" 'with."jf-bundle-name"')" = "test-docker-release" ]
        [ "$(job_get "$bundle_job" 'with."jf-project"')" = "test" ]
        [ "$(job_get "$bundle_job" 'with."gh-workflows-ref"')" = '${{ github.sha }}' ]
        [ -z "$(job_get "$bundle_job" 'with."jf-bundle-revision" // ""')" ]
        [ "$(job_get "$bundle_job" 'with."dry-run" // false')" = "false" ]

        local needs_count=0 names
        names="$(job_get "$bundle_job" 'with."jf-build-names"')"
        while IFS= read -r need; do
            [[ -n $need ]] || continue
            needs_count=$((needs_count + 1))
            [[ $names == *"needs.${need}.outputs.jf-build-name"* ]]
            [[ $names == *"needs.${need}.outputs.jf-build-id"* ]]
            [ "$(job_get "$need" 'with."image-name"')" = "$image" ]
            [ "$(job_get "$need" 'with."container-destination"')" = "$destination" ]
            [ "$(job_get "$need" 'with.push')" = "true" ]
            [ "$(job_get "$need" 'with."jf-project"')" = "test" ]
            [ "$(job_get "$need" 'with.context')" = "./.github/workflows/execute-build/test_apps/hi" ]
            [ "$(job_get "$need" 'with.file')" = "./.github/workflows/execute-build/test_apps/hi/Dockerfile" ]
            [[ "$(job_get "$need" 'uses')" == *reusable_docker-build-deploy.yaml ]]
            needs_of "$need" | grep -qx "$guard"

            local app build_name
            app="$(job_get "$need" 'with."app-version"')"
            build_name="$(job_get "$need" 'with."jf-build-name"')"
            [ -n "$app" ] && [ "$app" != "null" ]
            [ -n "$build_name" ] && [ "$build_name" != "null" ]
            [[ " $app_versions " != *" $app "* ]]
            [[ " $build_names " != *" $build_name "* ]]
            [[ " $seen_builds " != *" $need "* ]]
            app_versions+=" $app"
            build_names+=" $build_name"
            seen_builds+=" $need"
        done < <(needs_of "$bundle_job")
        [ "$needs_count" -eq "$count" ]
    done < <(bash "$SCRIPT" --dry-run)

    [ "$line_count" -eq "$(job_lines "reusable_create-release-bundle\\.yaml" | grep -c . || true)" ]
    [ "$(printf '%s\n' "$seen_builds" | tr ' ' '\n' | sed '/^$/d' | sort)" = "$(job_lines "reusable_docker-build-deploy\\.yaml" | sed '/^$/d' | sort)" ]

    while IFS= read -r job; do
        [[ -n $job ]] || continue
        if [[ $job == "$guard" ]]; then
            continue
        fi
        local uses
        uses="$(job_get "$job" 'uses // ""')"
        [[ $uses == *reusable_docker-build-deploy.yaml || $uses == *reusable_create-release-bundle.yaml ]]
    done < <(yq -r '.jobs | keys | .[]' "$WORKFLOW")
}
