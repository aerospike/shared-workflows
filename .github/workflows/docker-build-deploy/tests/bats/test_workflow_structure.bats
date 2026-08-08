#!/usr/bin/env bats
#
# Structural rules for reusable_docker-build-deploy.yaml: where steps sit, what
# gates them, and which job owns them.
#
# The other two suites in this directory test what each step's script does.
# Placement is what makes the delivery refusals cheap: a rejected input costs
# nothing because it is rejected before an OIDC token is minted, and a caller
# that asks for nothing runs none of it.

WORKFLOW="${BATS_TEST_DIRNAME}/../../../reusable_docker-build-deploy.yaml"

DELIVERY_STEPS=(
    "Validate build-context artifacts"
    "Download build-context artifacts"
    "Place build-context artifacts"
)

# step_names <job>
step_names() {
    python3 -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for step in doc["jobs"][sys.argv[2]]["steps"]:
    print(step.get("name") or step.get("uses", ""))
' "$WORKFLOW" "$1"
}

# step_field <step-name> <field>
step_field() {
    python3 -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for step in doc["jobs"]["build"]["steps"]:
    if (step.get("name") or "") == sys.argv[2]:
        print(step.get(sys.argv[3], ""))
        break
' "$WORKFLOW" "$1" "$2"
}

index_of() {
    step_names build | grep -nxF "$1" | cut -d: -f1
}

@test "the input is declared with an empty default" {
    run python3 -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
# YAML 1.1 resolves a bare "on:" key to the boolean True, so it is not "on".
triggers = doc.get("on", doc.get(True))
i = triggers["workflow_call"]["inputs"]["gh-context-artifacts-json"]
print(repr(i.get("default")))
' "$WORKFLOW"
    [ "$status" -eq 0 ]
    # "" and not "[]": the gate is an exact string comparison, and Actions
    # expressions cannot trim, so "[ ]" or a trailing newline would not match.
    [ "$output" = "''" ]
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
    run python3 -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
names = {"Validate build-context artifacts", "Download build-context artifacts",
         "Place build-context artifacts"}
for step in doc["jobs"]["build"]["steps"]:
    if (step.get("name") or "") in names:
        continue
    if "upload-artifact" in step.get("uses", "") and "ctxmeta" in str(step.get("with", "")):
        print("ctxmeta upload is back")
        sys.exit(1)
' "$WORKFLOW"
    [ "$status" -eq 0 ]
}

# --- build and merge topology ---------------------------------------------

@test "the image is attested exactly once" {
    run python3 -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
n = sum(1 for job in doc["jobs"].values()
        for step in (job.get("steps") or [])
        if "attest-build-provenance" in (step.get("uses") or ""))
print(n)
' "$WORKFLOW"
    [ "$output" = "1" ]
}

@test "attestation belongs to merge, not to a build leg" {
    # build is matrixed, so attesting there would attest each platform's image
    # separately instead of the manifest list consumers actually pull.
    run python3 -c '
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
for name, job in doc["jobs"].items():
    for step in (job.get("steps") or []):
        if "attest-build-provenance" in (step.get("uses") or ""):
            print(name)
' "$WORKFLOW"
    [ "$output" = "merge" ]
}
