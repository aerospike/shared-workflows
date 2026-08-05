#!/usr/bin/env bats

GIT_ROOT="$(git rev-parse --show-toplevel)"
ACTION_DIR="$GIT_ROOT/.github/actions/notify-slack"
PREP_SCRIPT="$ACTION_DIR/prep_blockkit.py"

setup() {
  export GITHUB_OUTPUT
  GITHUB_OUTPUT="$(mktemp)"
  export MESSAGE_TYPE=fail
  export TITLE="Build failed"
  export SUBTITLE="my-app@v1.0.0"
  export SLACK_CHANNEL_ID=C123
  export CHILD_BLOCKS='[{"type":"section","text":{"type":"mrkdwn","text":"details"}}]'
  export FALLBACK_TEXT=""
}

teardown() {
  rm -f "$GITHUB_OUTPUT"
}

payload_output() {
  grep '^payload_json_b64=' "$GITHUB_OUTPUT" | cut -d= -f2-
}

@test "prep skips when slack-channel-id is empty" {
  SLACK_CHANNEL_ID=""
  run python3 "$PREP_SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(payload_output)" = "" ]
  [[ "$output" == *"slack-channel-id is empty"* ]]
}

@test "prep writes payload_json_b64 when channel is set" {
  run python3 "$PREP_SCRIPT"
  [ "$status" -eq 0 ]
  b64="$(payload_output)"
  [ -n "$b64" ]
  decoded="$(B64="$b64" python3 -c 'import base64, json, os; print(json.dumps(json.loads(base64.b64decode(os.environ["B64"]))))')"
  [[ "$decoded" == *'"channel": "C123"'* ]]
  [[ "$decoded" == *'"block_id": "alert_fail"'* ]]
}

@test "prep fails on invalid child-blocks JSON" {
  CHILD_BLOCKS='not-json'
  run python3 "$PREP_SCRIPT"
  [ "$status" -eq 1 ]
}
