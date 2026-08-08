#!/usr/bin/env bats
#
# Structural rules for reusable_docker-build-deploy.yaml: where steps sit, what
# gates them, and which job owns them.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"

DELIVERY_STEPS=(
    "Validate build-context artifacts"
    "Download build-context artifacts"
    "Place build-context artifacts"
)

# step_names <job>
step_names() {
    yq -r ".jobs.\"$1\".steps[] | .name // .uses" "$WORKFLOW"
}

# step_field <step-name> <field>
step_field() {
    yq -r ".jobs.build.steps[] | select(.name == \"$1\") | .[\"$2\"] // \"\"" "$WORKFLOW"
}

index_of() {
    step_names build | grep -nxF "$1" | cut -d: -f1
}

@test "the input is declared with an empty default" {
    # "" and not "[]": the gate is an exact string comparison, and Actions
    # expressions cannot trim, so "[ ]" or a trailing newline would not match.
    local declared value
    declared="$(yq -r '.on.workflow_call.inputs["gh-context-artifacts-json"] | has("default")' "$WORKFLOW")"
    [ "$declared" = "true" ]
    value="$(yq -r '.on.workflow_call.inputs["gh-context-artifacts-json"].default' "$WORKFLOW")"
    [ -z "$value" ]
}

@test "every delivery step is in the matrixed build job" {
    local names
    names="$(step_names build)"
    for s in "${DELIVERY_STEPS[@]}"; do
        grep -qxF "$s" <<<"$names" || {
            echo "missing from build job: $s"
            return 1
        }
    done
}

@test "no delivery step leaked into the merge job" {
    local names
    names="$(step_names merge)"
    for s in "${DELIVERY_STEPS[@]}"; do
        if grep -qxF "$s" <<<"$names"; then
            echo "merge builds no image and needs no context, but has: $s"
            return 1
        fi
    done
}

@test "every delivery step is gated on the caller's input" {
    for s in "${DELIVERY_STEPS[@]}"; do
        local cond
        cond="$(step_field "$s" if)"
        case "$cond" in
            *gh-context-artifacts-json* | *ctx_artifacts.outputs.count*) ;;
            *)
                echo "ungated, so it would run for callers that asked for nothing: $s"
                return 1
                ;;
        esac
    done
}

@test "every delivery step runs before the OIDC token is minted" {
    local jfrog
    jfrog="$(index_of "Install JFrog CLI")"
    [ -n "$jfrog" ]
    for s in "${DELIVERY_STEPS[@]}"; do
        local i
        i="$(index_of "$s")"
        if [ "$i" -gt "$jfrog" ]; then
            echo "runs after Install JFrog CLI, so bad input would cost a token: $s"
            return 1
        fi
    done
}

@test "delivery happens after checkout, which creates the context" {
    local checkout
    checkout="$(step_names build | grep -n '^actions/checkout@' | cut -d: -f1)"
    [ -n "$checkout" ]
    for s in "${DELIVERY_STEPS[@]}"; do
        local i
        i="$(index_of "$s")"
        if [ "$i" -lt "$checkout" ]; then
            echo "runs before the context exists: $s"
            return 1
        fi
    done
}

@test "delivery leaves no artifact behind for consumers to pay for" {
    local n
    n="$(yq -r '[.jobs.build.steps[]
        | select((.uses // "") | test("upload-artifact"))
        | select((.with.name // "") | test("ctxmeta"))] | length' "$WORKFLOW")"
    [ "$n" = "0" ]
}

# --- build and merge topology ---------------------------------------------

@test "the image is attested exactly once" {
    local n
    n="$(yq -r '[.jobs[] | .steps[]?
        | select((.uses // "") | test("attest-build-provenance"))] | length' "$WORKFLOW")"
    [ "$n" = "1" ]
}

@test "attestation belongs to merge, not to a build leg" {
    # build is matrixed, so attesting there would attest each platform's image
    # separately instead of the manifest list consumers actually pull.
    local job
    job="$(yq -r '.jobs | to_entries[]
        | select(.value.steps[]?.uses // "" | test("attest-build-provenance"))
        | .key' "$WORKFLOW")"
    [ "$job" = "merge" ]
}
