# Send Slack Message

Low-level transport action that POSTs a prepared payload to Slack via `chat.postMessage`.

Use [`notify-slack`](../notify-slack/) to build Block Kit container alerts. Use this action directly when you already have a base64-encoded `chat.postMessage` payload.

See [Slack notification docs](../../workflows/docs/notify-slack.md) for the full consumer guide.

## Prerequisites

- `SLACK_BOT_TOKEN` must be available in the step or job environment for live posts (see [Authentication](#authentication)).
- Payload must be a valid `chat.postMessage` JSON object (typically includes `channel`, `text`, and `blocks`).
- Callers should skip this action when there is nothing to send (empty payload) or when live posting is requested without a token. [`notify-slack`](../notify-slack/) handles those skips upstream.

## Inputs

| Input              | Required | Default | Description                                    |
| ------------------ | -------- | ------- | ---------------------------------------------- |
| `payload-json-b64` | Yes      | —       | Base64-encoded `chat.postMessage` JSON payload |
| `dry-run`          | No       | `false` | Print payload to stdout without HTTP POST      |

## Outputs

None. Step **success** means the payload was dry-run printed or posted to Slack. Step **failure** means an empty/invalid payload, missing token on a live post, or a Slack API error.

## Authentication

This action does **not** accept a bot token input. Set `SLACK_BOT_TOKEN` via job or workflow `env:`.

For reusable workflows in this repo, the token comes from the **shared-workflows** repository secret `SLACK_BOT_TOKEN`:

```yaml
env:
  SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}
```

Repository admins must configure that secret before live posting works. Dry-run mode does not require a token.

## Failure behavior

| Condition                             | Result        |
| ------------------------------------- | ------------- |
| Empty `payload-json-b64`              | Step fails    |
| `dry-run=true`                        | Step succeeds |
| Missing `SLACK_BOT_TOKEN` (live post) | Step fails    |
| Invalid base64 / JSON payload         | Step fails    |
| Slack API error                       | Step fails    |

## Example usage

### Direct action (after checkout)

```yaml
steps:
  - uses: actions/checkout@v4
    with:
      sparse-checkout: .github/actions/send-slack
      sparse-checkout-cone-mode: false

  - name: Send Slack message
    if: steps.prep.outputs.payload-json-b64 != ''
    uses: ./.github/actions/send-slack
    env:
      SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}
    with:
      payload-json-b64: ${{ steps.prep.outputs.payload-json-b64 }}
```

### Dry-run (no token required)

```yaml
- uses: aerospike/shared-workflows/.github/actions/send-slack@<sha>
  with:
    payload-json-b64: eyJjaGFubmVsIjoiQzEyMyIsInRleHQiOiJoZWxsbyJ9
    dry-run: true
```

## Tests

```bash
python3 -m unittest discover .github/actions/send-slack/tests -p 'test_slack_post.py'
bats .github/actions/send-slack/tests/test_slack_post.bats
```
