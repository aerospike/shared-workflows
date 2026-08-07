# Slack notifications

Post Block Kit container alerts from CI via `reusable_notify-slack.yaml` or the composable `notify-slack` / `send-slack` actions.

## Architecture

```text
reusable_notify-slack.yaml
  └─ prep_blockkit.py + templates/container.json
  └─ send-slack → slack_post.py → Slack chat.postMessage
```

## Reusable workflow (recommended)

[`reusable_notify-slack.yaml`](../reusable_notify-slack.yaml) checks out `shared-workflows` (sparse: notify + send actions) and reads `SLACK_BOT_TOKEN` from the **shared-workflows** repo secret. Callers do not pass a Slack secret; they still provide `slack-channel-id`.

```yaml
notify-failure:
  if: failure()
  uses: aerospike/shared-workflows/.github/workflows/reusable_notify-slack.yaml@<sha> # vX.Y.Z
  with:
    gh-workflows-ref: <sha>
    message-type: fail
    title: CI failed
    subtitle: ${{ github.repository }}
    slack-channel-id: ${{ vars.SLACK_CHANNEL_ID }}
    child-blocks: |
      [
        {
          "type": "section",
          "text": {
            "type": "mrkdwn",
            "text": "<${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}|View workflow>"
          }
        }
      ]
```

### Message types

| `message-type` | Use case                |
| -------------- | ----------------------- |
| `info`         | Information-only notice |
| `fail`         | Failure alert           |
| `success`      | Success with details    |
| `blocked`      | Blocked / denied action |
| `warning`      | Warning (collapsible)   |

## Composable actions

When you need custom steps between build and send, checkout actions and call [`notify-slack`](../../actions/notify-slack/README.md) directly. See [`send-slack`](../../actions/send-slack/README.md) for transport-only usage.

## Secrets and setup

| Secret / var             | Where                        | Purpose                           |
| ------------------------ | ---------------------------- | --------------------------------- |
| `SLACK_BOT_TOKEN`        | shared-workflows repo secret | Bot token for live posts          |
| `SLACK_TEST_CHANNEL_ID`  | shared-workflows repo secret | Optional integration test channel |
| `slack-channel-id` input | Consumer repo vars/secrets   | Target channel per project        |

Configure `SLACK_BOT_TOKEN` on shared-workflows before live posting works. Dry-run mode does not require a token.

## Skip and failure behavior

Non-fatal skips (job succeeds):

- Empty `slack-channel-id` → no payload built, send step skipped
- Payload built but live post requested without `SLACK_BOT_TOKEN` → notice logged, send step skipped

Hard failures:

- Invalid `child-blocks` JSON during prep
- Empty payload passed to `send-slack` (callers should skip upstream)
- Missing `SLACK_BOT_TOKEN` on a live `send-slack` call (callers should skip upstream)
- Slack API error on live post

## Examples and tests

| Workflow                             | Purpose                                   |
| ------------------------------------ | ----------------------------------------- |
| `example_notify-slack.yaml`          | Dry-run matrix for all five message types |
| `test_notify-slack.yaml`             | Unit + bats tests on PR                   |
| `test_notify-slack-integration.yaml` | Optional live post (`live-post` input)    |
