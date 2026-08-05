#!/usr/bin/env bats

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/send-slack"
ENTRYPOINT="$ACTION_DIR/entrypoint.sh"

setup() {
  export GITHUB_OUTPUT
  GITHUB_OUTPUT="$(mktemp)"
  export DRY_RUN=false
  unset SLACK_BOT_TOKEN || true
  export PAYLOAD_JSON_B64
  PAYLOAD_JSON_B64="$(python3 -c 'import base64, json; print(base64.b64encode(json.dumps({"channel":"C1","text":"hello"}).encode()).decode())')"
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
}

posted_output() {
  grep '^posted=' "$GITHUB_OUTPUT" | cut -d= -f2-
}

@test "entrypoint skips when payload is empty" {
  PAYLOAD_JSON_B64=""
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ "$(posted_output)" = "false" ]
  [[ "$output" == *"payload_json_b64 is empty"* ]]
}

@test "entrypoint skips when token missing and not dry-run" {
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ "$(posted_output)" = "false" ]
  [[ "$output" == *"SLACK_BOT_TOKEN is not set"* ]]
}

@test "entrypoint succeeds with dry-run and no token" {
  DRY_RUN=true
  run bash "$ENTRYPOINT"
  [ "$status" -eq 0 ]
  [ "$(posted_output)" = "true" ]
  [[ "$output" == *'"channel":"C1"'* ]]
}
