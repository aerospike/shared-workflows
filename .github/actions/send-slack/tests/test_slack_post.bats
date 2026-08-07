#!/usr/bin/env bats

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/send-slack"
SLACK_POST="$ACTION_DIR/slack_post.py"

setup() {
  export PAYLOAD_JSON_B64
  PAYLOAD_JSON_B64="$(printf '%s' '{"channel":"C1","text":"hello"}' | base64 | tr -d '\n')"
  unset SLACK_BOT_TOKEN || true
}

@test "slack_post fails when payload is empty" {
  unset PAYLOAD_JSON_B64
  run python3 "$SLACK_POST" --payload-b64 "" 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"payload is empty"* ]]
}

@test "slack_post fails when token missing and not dry-run" {
  run python3 "$SLACK_POST" --payload-b64 "$PAYLOAD_JSON_B64" 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"SLACK_BOT_TOKEN is not set"* ]]
}

@test "slack_post succeeds with dry-run and no token" {
  run python3 "$SLACK_POST" --payload-b64 "$PAYLOAD_JSON_B64" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *'"channel":"C1"'* ]]
}
