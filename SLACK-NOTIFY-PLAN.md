# Plan: Common Slack Notification Action & Reusable Workflow

Extract Slack **transport** (`send-slack`) and a **generalized alert builder** (`notify-slack`) from `artifact-publisher` into `shared-workflows`, so any Aerospike repo can post consistent Block Kit container messages without copying Python scripts.

## Architecture

```text
Consumer repo
  └─ reusable_notify-slack.yaml  (or direct notify-slack action)
       └─ notify-slack action
            ├─ prep_blockkit.py + templates/
            └─ send-slack action
                 └─ slack_post.py → Slack chat.postMessage
```

| Layer          | Responsibility                                         |
| -------------- | ------------------------------------------------------ |
| `notify-slack` | Map inputs → Block Kit payload; decide whether to send |
| `send-slack`   | POST a prepared payload to Slack API                   |

---

## Phase 1 — Copy `send-slack` (transport only)

### Files to add

```text
.github/actions/send-slack/
├── action.yaml
├── slack_post.py        # copy verbatim from artifact-publisher
├── README.md
└── tests/
    └── test_slack_post.py
```

- [Done] Copy `slack_post.py` from `artifact-publisher/.github/scripts/notify-scripts/slack_post.py`
- [Done] Create `action.yaml` with updated contract (see below)
- [Done] Port `tests/test_slack_post.py` from artifact-publisher
- [Done] Write `README.md`

### Action contract

**Inputs** (reduced — no `should_notify`, no `slack-bot-token`):

| Input              | Required | Default | Description                                    |
| ------------------ | -------- | ------- | ---------------------------------------------- |
| `payload-json-b64` | yes      | —       | Base64-encoded `chat.postMessage` JSON payload |
| `dry-run`          | no       | `false` | Print payload without HTTP POST                |

**Outputs**:

| Output   | Description                                           |
| -------- | ----------------------------------------------------- |
| `posted` | `true` when a message was posted (or dry-run printed) |

**Environment** (not inputs):

| Variable          | Source                                                         |
| ----------------- | -------------------------------------------------------------- |
| `SLACK_BOT_TOKEN` | shared-workflows repo secret, injected via workflow/job `env:` |

Composite actions cannot declare secrets. The reusable workflow (Phase 3) and test workflows set:

```yaml
env:
  SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}
```

### `action.yaml` behavior

- [Done] Remove `should_notify` check — if `send-slack` is called, posting is intended
- [Done] Remove `--bot-token` CLI pass-through — `slack_post.py` reads `SLACK_BOT_TOKEN` from env
- [Done] Update script path to `${{ github.action_path }}/slack_post.py`

Skip rules (non-fatal):

| Condition                             | Behavior                                      |
| ------------------------------------- | --------------------------------------------- |
| Empty `payload-json-b64`              | Skip, `posted=false`, log notice              |
| `dry-run=true`                        | Print payload, `posted=true`, no token needed |
| Missing `SLACK_BOT_TOKEN` (live post) | Skip, `posted=false`, log notice              |

Hard failures (unchanged from source):

- Invalid base64 / JSON payload → exit 1
- Slack API error → exit 1

### Secret setup (shared-workflows repo)

- [Not started] Add repository (or org) secret `SLACK_BOT_TOKEN` (`xoxb-…`) — manual GitHub repo settings

### Tests

- [Done] Port unit tests for `slack_post.py` (dry-run, API errors, payload loading)
- [Done] Verify bash wrapper skips when `SLACK_BOT_TOKEN` unset and `dry-run=false`
- [Done] Verify bash wrapper succeeds with `dry-run=true` and no token

---

## Phase 2 — Create generalized `notify-slack`

```text
.github/actions/notify-slack/
├── action.yaml
├── prep_blockkit.py       # adapted from artifact-publisher
├── templates/
│   ├── info.container.json      ← success.noop.container.json
│   ├── fail.container.json      ← failure.container.json
│   ├── success.container.json   ← success.container.json
│   ├── blocked.container.json   ← blocked.container.json
│   └── warning.container.json   ← slow.container.json
├── README.md
└── tests/
    └── test_prep_blockkit.py
```

### Actions

- [Done] Copy and generalize templates from artifact-publisher (strip publish-specific child content)
- [Done] Adapt `prep_blockkit.py` for input-driven rendering + `child-blocks` merge
- [Done] Create `action.yaml` wiring build → send
- [Done] Port/adapt unit tests
- [Done] Write `README.md`

### Message types

<!-- markdownlint-disable MD060 -->

| Input `message-type` | Template                 | Source in artifact-publisher  | Icon                       |
| -------------------- | ------------------------ | ----------------------------- | -------------------------- |
| `info`               | `info.container.json`    | `success.noop.container.json` | ℹ️ info                    |
| `fail`               | `fail.container.json`    | `failure.container.json`      | ❌ cross mark              |
| `success`            | `success.container.json` | `success.container.json`      | ✅ check mark              |
| `blocked`            | `blocked.container.json` | `blocked.container.json`      | 🛑 stop sign               |
| `warning`            | `warning.container.json` | `slow.container.json`         | ⏳ hourglass (collapsible) |

<!-- markdownlint-restore -->

### Action inputs

| Input              | Required | Default               | Description                                        |
| ------------------ | -------- | --------------------- | -------------------------------------------------- |
| `message-type`     | yes      | —                     | `info`, `fail`, `success`, `blocked`, or `warning` |
| `title`            | yes      | —                     | Plain-text container title                         |
| `subtitle`         | yes      | —                     | Plain-text container subtitle                      |
| `slack-channel-id` | yes      | —                     | Slack channel ID (`C…`)                            |
| `child-blocks`     | no       | `[]`                  | JSON array of Block Kit blocks                     |
| `fallback-text`    | no       | `{title}: {subtitle}` | `chat.postMessage` `text` fallback                 |
| `dry-run`          | no       | `false`               | Print payload, do not POST                         |

No `slack-bot-token` input — inherited from job `env: SLACK_BOT_TOKEN`.

### Action outputs

| Output             | Description                             |
| ------------------ | --------------------------------------- |
| `payload-json-b64` | Rendered payload (debugging / chaining) |
| `posted`           | From `send-slack`                       |

No `should_notify` output — skip logic uses conditional step invocation.

### Action steps

1. [Done] **Validate & build payload** — run `prep_blockkit.py`
2. [Done] **Send** — call `./.github/actions/send-slack` (only when payload is non-empty)

```yaml
- name: Send Slack message
  if: steps.prep.outputs.payload_json_b64 != ''
  uses: ./.github/actions/send-slack
  with:
    payload-json-b64: ${{ steps.prep.outputs.payload_json_b64 }}
    dry-run: ${{ inputs.dry-run }}
```

### Template design: `child-blocks` injection

Templates define only the **container shell** (icon, title, subtitle, collapsible flags). Caller-supplied `child-blocks` replaces the container's `child_blocks` array.

Generalized template shape:

```json
{
	"text": "{fallback_text}",
	"blocks": [
		{
			"type": "container",
			"title": { "type": "plain_text", "text": "{title}", "emoji": true },
			"subtitle": { "type": "plain_text", "text": "{subtitle}" },
			"icon": { "...": "..." },
			"child_blocks": []
		}
	]
}
```

### `prep_blockkit.py` changes vs artifact-publisher

| Remove                                       | Add                                                        |
| -------------------------------------------- | ---------------------------------------------------------- |
| `load_alert_view()` / publish domain routing | `message-type` → template file map                         |
| `variables_from_view()` over full alert view | Inputs: `title`, `subtitle`, `fallback_text`, `channel_id` |
| Publish-specific template selection          | Explicit `message-type` input                              |
| —                                            | Parse `child-blocks` JSON; validate array of objects       |
| —                                            | Replace `container.child_blocks` with parsed input         |
| —                                            | Set `payload.channel` from `slack-channel-id`              |

### Skip rules (non-fatal, emit `::notice::`)

- [Done] `slack-channel-id` empty → skip send step (no payload built)
- [Done] `dry-run=true` → build payload, print via `send-slack`, `posted=true`

Hard failures:

- Invalid `message-type`
- `child-blocks` not valid JSON or not an array
- Slack API error (from `send-slack`)

### Template cleanup

- [Done] Rename `block_id` values from `publish_*` to neutral ids (`alert_fail`, `alert_warning`, etc.)

---

## Phase 3 — Reusable workflow

### File

`.github/workflows/reusable_notify-slack.yaml`

- [Done] Create reusable workflow

### Inputs

Mirror action inputs, plus standard shared-workflows boilerplate:

| Input              | Required | Default            |
| ------------------ | -------- | ------------------ |
| `message-type`     | yes      | —                  |
| `title`            | yes      | —                  |
| `subtitle`         | yes      | —                  |
| `slack-channel-id` | yes      | —                  |
| `gh-workflows-ref` | yes      | —                  |
| `child-blocks`     | no       | `[]`               |
| `fallback-text`    | no       | `""`               |
| `dry-run`          | no       | `false`            |
| `runs-on`          | no       | `ubuntu-22.04`     |
| `gh-checkout-path` | no       | `shared-workflows` |

**No `secrets:` block on `workflow_call`** — bot token comes from shared-workflows repo secret directly:

```yaml
env:
  SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}
```

Consumers do not pass a Slack secret. Channel ID may still come from the consumer repo (`vars` or `secrets`) since channels differ per project.

### Job flow

- [Done] Harden runner (match existing workflows)
- [Done] Sparse-checkout shared-workflows (`.github/actions/send-slack`, `.github/actions/notify-slack`)
- [Done] Set `SLACK_BOT_TOKEN` from repo secret at job level
- [Done] Run `prep_blockkit.py` and `send-slack/entrypoint.sh` (supports `gh-checkout-path`; avoids dynamic `uses:`)

### Permissions

```yaml
permissions:
  contents: read
```

---

## Phase 4 — Tests & examples

### Unit tests (CI)

File: `.github/workflows/test_notify-slack.yaml`

- [Done] Create test workflow (pattern from `test_extract-version-from-tag.yaml`)
- [Done] Run `python3 -m unittest discover .github/actions/notify-slack/tests`
- [Done] Run `python3 -m unittest discover .github/actions/send-slack/tests`

### Example workflow

File: `.github/workflows/example_notify-slack.yaml`

- [Not started] Create `workflow_dispatch` example with `dry-run: true`
- [Not started] Demonstrate each `message-type` with sample `child-blocks`

### Manual integration test (optional)

- [Not started] Separate `workflow_dispatch` job posting to a test channel when `SLACK_BOT_TOKEN` + test channel ID are configured

---

## Phase 5 — Documentation

- [Done] Write `send-slack/README.md` (transport-only; env-based token; no notify gate)
- [Done] Write `notify-slack/README.md` (message types, `child-blocks` examples, consumer usage)
- [Not started] Update `CLAUDE.md` with new actions and reusable workflow
- [Not started] Mark this plan file steps `[Done]` as work completes

---

## Consumer usage examples

### Reusable workflow (recommended)

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
  # no secrets: block — bot token is on shared-workflows
```

### Direct action (caller already checked out shared-workflows)

```yaml
- uses: aerospike/shared-workflows/.github/actions/notify-slack@<sha>
  env:
    SLACK_BOT_TOKEN: ${{ secrets.SLACK_BOT_TOKEN }}
  with:
    message-type: fail
    title: Build failed
    subtitle: my-app@v1.2.3
    slack-channel-id: ${{ vars.SLACK_CHANNEL_ID }}
    child-blocks: |
      [
        {
          "type": "section",
          "fields": [
            { "type": "mrkdwn", "text": "*Repository*\n`${{ github.repository }}`" },
            { "type": "mrkdwn", "text": "*Failed job*\n`${{ github.job }}`" }
          ]
        },
        {
          "type": "section",
          "text": { "type": "mrkdwn", "text": "<${{ github.server_url }}/${{ github.repository }}/actions/runs/${{ github.run_id }}|View workflow>" }
        }
      ]
```

---

## Future follow-up (out of scope)

Migrate `artifact-publisher` to consume shared `notify-slack`:

1. Keep `publish_notify.py` for domain logic (job results, registry links, skip rules)
2. Have it output `title`, `subtitle`, and a pre-built `child-blocks` JSON array
3. Call `aerospike/shared-workflows/.github/actions/notify-slack@…` with mapped `message-type`:

| Current alert        | New `message-type` |
| -------------------- | ------------------ |
| failure              | `fail`             |
| slow                 | `warning`          |
| success (with links) | `success`          |
| success (noop)       | `info`             |
| blocked\_\*          | `blocked`          |

---

## Open decisions

1. **Fail on missing token vs skip** — recommend skip (consistent with artifact-publisher; won't break CI when secret isn't configured)
2. **`child-blocks` max size** — Slack block limits (~50 blocks); document and optionally validate in `prep_blockkit.py`
3. **Version bump** — ship as next semver minor (e.g. v2.1.0) with SHA pin docs

---

## Implementation order

1. [Done] Phase 1 — `send-slack` (copy, path fix, unit tests, README, repo secret)
2. [Done] Phase 2 — `notify-slack` templates, `prep_blockkit.py`, action, tests
3. [Done] Phase 3 — `reusable_notify-slack.yaml`
4. [Not started] Phase 4 — CI test workflow + example workflow
5. [Not started] Phase 5 — Documentation (`README.md`, `CLAUDE.md`)
