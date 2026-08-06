# Send Slack Message

Low-level transport action that POSTs a prepared payload to Slack via `chat.postMessage`.

Use [`notify-slack`](../notify-slack/) to build Block Kit container alerts. Use this action directly when you already have a base64-encoded `chat.postMessage` payload.

See [Slack notification docs](../../workflows/docs/notify-slack.md) for the full consumer guide.

## Prerequisites

- `SLACK_BOT_TOKEN` must be available in the step or job environment (see [Authentication](#authentication)).
- Payload must be a valid `chat.postMessage` JSON object (typically includes `channel`, `text`, and `blocks`).

## Inputs

| Input              | Required | Default | Description                                    |
| ------------------ | -------- | ------- | ---------------------------------------------- |
| `payload-json-b64` | Yes      | —       | Base64-encoded `chat.postMessage` JSON payload |
| `dry-run`          | No       | `false` | Print payload to stdout without HTTP POST      |

## Outputs

| Output   | Description                                                                 |
| -------- | --------------------------------------------------------------------------- |
| `posted` | `true` when a message was posted (or dry-run printed); `false` when skipped |

## Authentication

This action does **not** accept a bot token input. Set `SLACK_BOT_TOKEN` via job or workflow `env:`.

For reusable workflows in this repo, the token comes from the **shared-workflows** repository secret `SLACK_BOT_TOKEN`:

```yaml
env:
  SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}
```

Repository admins must configure that secret before live posting works. Dry-run mode does not require a token.

## Skip behavior

These conditions skip posting without failing the step:

| Condition                             | Result                       |
| ------------------------------------- | ---------------------------- |
| Empty `payload-json-b64`              | Skip, `posted=false`         |
| `dry-run=true`                        | Print payload, `posted=true` |
| Missing `SLACK_BOT_TOKEN` (live post) | Skip, `posted=false`         |

Hard failures:

- Invalid base64 or JSON payload
- Slack API error

## Example usage

### Direct action (after checkout)

```yaml
steps:
  - uses: actions/checkout@v4
    with:
      sparse-checkout: .github/actions/send-slack
      sparse-checkout-cone-mode: false

  - name: Send Slack message
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
bats .github/actions/send-slack/tests/test_entrypoint.bats
```
