# Notify Slack

Build a Block Kit container alert and send it via [`send-slack`](../send-slack/).

Use this action when you want a consistent Aerospike Slack alert layout with a typed icon/title/subtitle shell and caller-supplied detail blocks. Per-type values (`block_id`, icon URL/alt text, collapsible flags) live in `MESSAGE_TYPE_CONFIG` inside `prep_blockkit.py` and are substituted into `templates/container.json`.

## Prerequisites

- Check out `shared-workflows` (sparse checkout of `.github/actions/notify-slack` and `.github/actions/send-slack` is enough).
- Set `SLACK_BOT_TOKEN` on the job or workflow `env:` (shared-workflows repo secret for reusable workflows).
- Provide a Slack channel ID (`C…`).

## Message types

| `message-type` | Use case                           |
| -------------- | ---------------------------------- |
| `info`         | Information-only notice            |
| `fail`         | Failure alert                      |
| `success`      | Success with optional detail/links |
| `blocked`      | Blocked or denied action           |
| `warning`      | Warning (collapsible container)    |

## Inputs

| Input              | Required | Default               | Description                                                |
| ------------------ | -------- | --------------------- | ---------------------------------------------------------- |
| `message-type`     | Yes      | —                     | `info`, `fail`, `success`, `blocked`, or `warning`         |
| `title`            | Yes      | —                     | Container title                                            |
| `subtitle`         | Yes      | —                     | Container subtitle                                         |
| `slack-channel-id` | Yes      | —                     | Slack channel ID                                           |
| `child-blocks`     | No       | `[]`                  | JSON array of Block Kit blocks inserted into the container |
| `fallback-text`    | No       | `{title}: {subtitle}` | `chat.postMessage` `text` fallback                         |
| `dry-run`          | No       | `false`               | Print payload without HTTP POST                            |

## Outputs

| Output             | Description                                     |
| ------------------ | ----------------------------------------------- |
| `payload-json-b64` | Rendered Block Kit payload (empty when skipped) |
| `posted`           | From `send-slack`                               |

## Skip behavior

Non-fatal skips:

- Empty `slack-channel-id` → no payload built, send step skipped

Hard failures:

- Invalid `message-type`
- `child-blocks` not valid JSON or not an array of objects
- Slack API error (from `send-slack`)

## Example usage

```yaml
steps:
  - uses: actions/checkout@v4
    with:
      sparse-checkout: |
        .github/actions/notify-slack
        .github/actions/send-slack
      sparse-checkout-cone-mode: false

  - name: Notify Slack
    uses: ./.github/actions/notify-slack
    env:
      SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}
    with:
      message-type: fail
      title: CI failed
      subtitle: ${{ github.repository }}
      slack-channel-id: ${{ vars.SLACK_CHANNEL_ID }}
      child-blocks: |
        [
          {
            "type": "section",
            "fields": [
              { "type": "mrkdwn", "text": "*Repository*\n`${{ github.repository }}`" },
              { "type": "mrkdwn", "text": "*Run*\n<${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}|View workflow>" }
            ]
          }
        ]
```

## Reusable workflow

```yaml
notify-failure:
  if: failure()
  uses: aerospike/shared-workflows/.github/workflows/reusable_notify-slack.yaml@<sha>
  with:
    gh-workflows-ref: <sha>
    message-type: fail
    title: CI failed
    subtitle: ${{ github.repository }}
    slack-channel-id: ${{ vars.SLACK_CHANNEL_ID }}
    child-blocks: ${{ steps.build-alert.outputs.child_blocks_json }}
```

The reusable workflow checks out `shared-workflows` (sparse: `notify-slack` + `send-slack` actions) and reads `SLACK_BOT_TOKEN` from the shared-workflows repo secret — callers do not pass a Slack secret.

## Tests

```bash
python3 -m unittest discover .github/actions/notify-slack/tests
bats .github/actions/notify-slack/tests/test_prep_blockkit.bats
```
