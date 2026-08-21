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

## Failure notifications in pipelines

Terminal reusables (`reusable_sign-artifacts`, `reusable_deploy-artifacts`, `reusable_create-release-bundle`) can post a Slack alert when the job fails. Enable with `slack-notify-on-failure: true` plus `vars.SLACK_CHANNEL_ID` and `secrets.SLACK_BOT_TOKEN` on the caller (`secrets: inherit`). Alerts include failed step names from the job and a link to the workflow run.

Alternatively, add a **caller-side** tail job that uses [`reusable_notify-slack.yaml`](../reusable_notify-slack.yaml) with `if: failure()` and `needs:` on your job graph. That yields one message per workflow run with summary context you define in `child-blocks`.

**Pick one pattern, not both.** Embedded notify on a reusable plus a caller `notify-failure` job duplicates alerts for the same failure.

### Orchestrated pipelines (`reusable_artifacts-cicd`)

The artifacts orchestrator runs a matrix build, collect, sign chain, and deploy. Embedded notify on every stage would multiply alerts (for example, one per matrix leg if build ever notified, or sign plus deploy on a cascade).

| Approach                                | When to use                                                                                                                                                                                |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Embedded notify on **one terminal job** | Enable `slack-notify-on-failure: true` on at most one stage—usually `deploy-signed`. If deploy is skipped because sign failed, enable it on `sign` instead, but still only on **one** job. |
| Caller `notify-failure` job             | One alert per run; keep `slack-notify-on-failure: false` on all reusables and use `needs:` on resolve, build, collect, sign, and deploy jobs.                                              |
| Both embedded and caller notify         | Avoid—same failure posts twice.                                                                                                                                                            |

`reusable_execute-build` and intermediate jobs (collect, sign-mac, sign-windows) do **not** embed failure notify, to avoid matrix and chain spam.

### Composable callers (direct stage invoke)

Calling sign, deploy, or create-release-bundle directly is the sweet spot for embedded notify: one job fails, one Slack message with step-level detail from [`notify-workflow-failure`](../../actions/notify-workflow-failure/action.yaml).

See also: [deploy-artifacts README](../deploy-artifacts/README.md), [sign-artifacts README](../sign-artifacts/README.md), [create-release-bundle README](../create-release-bundle/README.md).

## Secrets and setup

| Secret / var             | Where                                                       | Purpose                           |
| ------------------------ | ----------------------------------------------------------- | --------------------------------- |
| `SLACK_BOT_TOKEN`        | Caller repo secret (or shared-workflows for internal tests) | Bot token for live posts          |
| `SLACK_TEST_CHANNEL_ID`  | shared-workflows repo secret                                | Optional integration test channel |
| `slack-channel-id` input | Consumer repo vars/secrets                                  | Target channel per project        |

Configure `SLACK_BOT_TOKEN` on the caller repo (or on shared-workflows for internal example/test workflows) before live posting works. Dry-run mode does not require a token.

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
