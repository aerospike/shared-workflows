#!/usr/bin/env bats

GIT_ROOT="$(git rev-parse --show-toplevel)"
CHECKER="$GIT_ROOT/.github/workflows/lib/check_reusable_workflow_permissions.sh"
WORKFLOWS_DIR="$GIT_ROOT/.github/workflows"

setup_file() {
  chmod +x "$CHECKER"
}

@test "reusable workflow permission checker passes on repository workflows" {
  run "$CHECKER" "$WORKFLOWS_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All reusable workflow permission scopes are valid."* ]]
}

@test "reusable_create-release-bundle has no workflow-scoped actions: read" {
  file="$WORKFLOWS_DIR/reusable_create-release-bundle.yaml"
  run awk '
    BEGIN { in_perms = 0; bad = 0 }
    /^permissions:[[:space:]]*$/ { in_perms = 1; next }
    in_perms {
      if ($0 ~ /^[^[:space:]]/) { exit }
      if ($0 ~ /^  actions:[[:space:]]*/) { bad = 1 }
    }
    END { exit bad ? 1 : 0 }
  ' "$file"
  [ "$status" -eq 0 ]
}

@test "reusable_deploy-artifacts has no workflow-scoped actions: write" {
  file="$WORKFLOWS_DIR/reusable_deploy-artifacts.yaml"
  run awk '
    BEGIN { in_perms = 0; bad = 0 }
    /^permissions:[[:space:]]*$/ { in_perms = 1; next }
    in_perms {
      if ($0 ~ /^[^[:space:]]/) { exit }
      if ($0 ~ /^  actions:[[:space:]]*/) { bad = 1 }
    }
    END { exit bad ? 1 : 0 }
  ' "$file"
  [ "$status" -eq 0 ]
}

@test "reusable_create-release-bundle declares no job-scoped actions permission" {
  file="$WORKFLOWS_DIR/reusable_create-release-bundle.yaml"
  run awk '
    BEGIN { in_jobs = 0; in_job_perms = 0; bad = 0 }
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    in_jobs {
      if ($0 ~ /^[^[:space:]]/) { exit }
      if ($0 ~ /^    permissions:[[:space:]]*$/) { in_job_perms = 1; next }
      if (in_job_perms && $0 ~ /^      actions:[[:space:]]*/) { bad = 1 }
    }
    END { exit bad ? 1 : 0 }
  ' "$file"
  [ "$status" -eq 0 ]
}

@test "reusable_deploy-artifacts declares no job-scoped actions permission" {
  file="$WORKFLOWS_DIR/reusable_deploy-artifacts.yaml"
  run awk '
    BEGIN { in_jobs = 0; in_job_perms = 0; bad = 0 }
    /^jobs:[[:space:]]*$/ { in_jobs = 1; next }
    in_jobs {
      if ($0 ~ /^[^[:space:]]/) { exit }
      if ($0 ~ /^    permissions:[[:space:]]*$/) { in_job_perms = 1; next }
      if (in_job_perms && $0 ~ /^      actions:[[:space:]]*/) { bad = 1 }
    }
    END { exit bad ? 1 : 0 }
  ' "$file"
  [ "$status" -eq 0 ]
}

@test "checker rejects workflow-scoped actions permissions in a synthetic workflow" {
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN
  cat >"$tmpdir/reusable_bad-example.yaml" <<'YAML'
name: Bad Example
on:
  workflow_call:
    inputs:
      gh-workflows-ref:
        required: true
        type: string
permissions:
  contents: read
  id-token: write
  actions: read
jobs:
  example:
    runs-on: ubuntu-22.04
    steps:
      - run: echo bad
YAML
  run "$CHECKER" "$tmpdir"
  [ "$status" -ne 0 ]
  [[ "$output" == *"workflow-level permission 'actions'"* ]]
}
