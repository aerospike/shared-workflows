# PR Hygiene

Reusable workflow that validates PR titles with [commitlint](https://commitlint.js.org/) (`@commitlint/config-conventional`) and, for selected types, requires a Jira ticket. A sibling merge workflow can prepend that ticket onto the merge commit.

| Workflow         | Path                                                                | Role                                                           |
| ---------------- | ------------------------------------------------------------------- | -------------------------------------------------------------- |
| PR Hygiene       | [`reusable_pr-hygiene.yml`](../reusable_pr-hygiene.yml)             | Validate the PR title                                          |
| PR Hygiene merge | [`reusable_pr-hygiene-merge.yml`](../reusable_pr-hygiene-merge.yml) | Re-run hygiene, then prepend the Jira id onto the merge commit |

This repo's caller is [`pr-hygiene.yaml`](../pr-hygiene.yaml) (`pr_title` + `pr-labels`).

## Checks

`reusable_pr-hygiene.yml` runs these steps in order. The first match that skips later steps wins.

| Order | Check               | Runs when                                      | Pass / skip condition                                                                                                                                                                                           |
| ----- | ------------------- | ---------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1     | Allowlist           | Always                                         | Title matches any `allowed-patterns` ERE regex. On match, commitlint and Jira are both skipped.                                                                                                                 |
| 2     | Conventional commit | Allowlist did not match                        | `npx commitlint` with `@commitlint/config-conventional` accepts the title. Allowed types: `build`, `chore`, `ci`, `docs`, `feat`, `fix`, `perf`, `refactor`, `revert`, `style`, `test`.                         |
| 3     | `skip-jira` label   | Allowlist did not match                        | `pr-labels` JSON contains `skip-jira-label` (default `skip-jira`). Commitlint has already run; Jira is skipped. Without `pr-labels`, this check cannot fire.                                                    |
| 4     | Type gate           | Allowlist did not match and label did not skip | Commit type is compared to `types-requiring-jira` (default `feat, fix`). Types **not** in the list skip Jira. An empty string skips Jira for every type.                                                        |
| 5     | Jira ticket         | Type is in `types-requiring-jira`              | Title matches `type(scope)!: [KEY-123] description`: lowercase type, optional scope (`[a-z0-9-_]+`), optional `!`, then an uppercase 2–10 letter project key and issue number in brackets, followed by a space. |

`reusable_pr-hygiene-merge.yml` calls check 1–5 with only `pr_title` (so `skip-jira` cannot fire, and Jira defaults to `feat`/`fix`). It then extracts the first `[A-Za-z0-9]+-[0-9]+` **anywhere** in the title (looser than check 5). If found and not already in the merge commit message, it amends the commit to `TICKET: <existing message>`, force-pushes `base_ref`, and comments on the merged PR.

## PR title format

```text
type(scope)!: [JIRA-123] description
```

- **type**: conventional commit type (commitlint)
- **scope**: optional, lowercase alphanumeric with hyphens and underscores
- **!**: optional breaking-change marker (`feat!:` or `feat(scope)!:`)
- **Jira**: uppercase project key in brackets, required only for types in `types-requiring-jira`

Examples:

- `feat(workflows): [INFRA-370] add artifacts-cicd integration tests`
- `fix(deploy): [ENG-123] correct artifact routing logic`
- `feat!: [INFRA-649] Major release on breaking API changes`
- `chore: update dependencies`

## Types and Jira enforcement

Not every commit type needs a Jira ticket. The defaults split `feat|fix` into two groups, based on whether the change should be traceable back to a planned work item.

| Commit type                                                                   | Jira ticket (default) |
| ----------------------------------------------------------------------------- | --------------------- |
| `feat`, `fix`                                                                 | Required              |
| `build`, `chore`, `ci`, `docs`, `perf`, `refactor`, `revert`, `style`, `test` | Optional              |

Required types correspond to user-visible or traceable work: new features, bug fixes, meaningful refactors, published docs, and CI changes that affect how the project is built or released. Optional types cover housekeeping, dependency bumps, internal tests, and performance tuning that often lacks a dedicated ticket.

Override with the `types-requiring-jira` input to narrow, expand, or disable Jira enforcement for your repo. Setting it to the empty string disables Jira enforcement entirely.

## Bypassing Jira enforcement

Sometimes a required-type PR legitimately has no Jira ticket (an urgent fix, an externally driven change, a cleanup merged during a freeze). Two bypass mechanisms are available, in priority order:

1. **The `skip-jira` label.** Add the `skip-jira` label to the PR (name configurable via `skip-jira-label`). Commitlint still runs, but the Jira ticket requirement is skipped. The caller must also pass the PR's labels via `pr-labels` for the label check to work. See the [example](#example-usage) below.
2. **The [allowlist](#allowlist-for-automated-prs).** If the PR title matches one of the `allowed-patterns` regexes, both commitlint and Jira validation are skipped. Use this for bot-generated PRs and other predictable title shapes, not for one-off human overrides.

## Allowlist for Automated PRs

The hygiene workflow includes an allowlist that lets certain PR titles bypass both commitlint and JIRA validation. This is useful for automated PRs from bots and standard git operations.

## Default Patterns and Allowlist

Titles matching `allowed-patterns` skip commitlint and Jira. Override replaces the list entirely; to keep the defaults, repeat them and append.

| Pattern                    | Matches                                                |
| -------------------------- | ------------------------------------------------------ |
| `^[a-zA-Z]+\(deps[^)]*\):` | Dependabot bumps (any type, `deps` / `deps-dev` scope) |
| `^\[StepSecurity\]`        | StepSecurity bot PRs                                   |
| `^[Rr]evert "`             | Git revert commits (`Revert "..."` )                   |
| `^revert:`                 | Conventional commit reverts                            |
| `^Bump`                    | Titles starting with `Bump`                            |

### Adding Custom Patterns

To add patterns while keeping the defaults, include them alongside the built-in ones:

```yaml
jobs:
  validate:
    uses: aerospike/shared-workflows/.github/workflows/reusable_pr-hygiene.yml@<sha> # vX.Y.Z
    with:
      pr_title: ${{ github.event.pull_request.title }}
      allowed-patterns: |
        ^[a-zA-Z]+\(deps[^)]*\):
        ^\[StepSecurity\]
        ^[Rr]evert "
        ^revert:
        ^Bump
        ^chore\(release\):
```

## Inputs

| Input                  | Required | Default                                                                                | Description                                                                                                               |
| ---------------------- | -------- | -------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| `pr_title`             | Yes      |                                                                                        | PR title to validate                                                                                                      |
| `allowed-patterns`     | No       | Dependabot, StepSecurity, revert, Bump (see [Allowlist](#allowlist-for-automated-prs)) | Newline-delimited ERE patterns. Matching titles bypass all validation.                                                    |
| `types-requiring-jira` | No       | `feat, fix`                                                                            | Comma-separated conventional commit types that require a Jira ticket. Empty string disables Jira.                         |
| `skip-jira-label`      | No       | `skip-jira`                                                                            | PR label that bypasses Jira validation. Commitlint still runs.                                                            |
| `pr-labels`            | No       | `""`                                                                                   | JSON array of PR label names (`toJSON(github.event.pull_request.labels.*.name)`). Required for the skip-jira label check. |

## Example Usage

Consumer repos call the reusable workflow via the fully-qualified path with a pinned SHA and semver comment:

```yaml
name: PR Hygiene

on:
  pull_request:
    types: [opened, edited, synchronize, reopened]

permissions:
  contents: read

jobs:
  validate:
    uses: aerospike/shared-workflows/.github/workflows/reusable_pr-hygiene.yml@<sha> # vX.Y.Z
    with:
      pr_title: ${{ github.event.pull_request.title }}
      pr-labels: ${{ toJSON(github.event.pull_request.labels.*.name) }}
```

Passing `pr-labels` is what lets the `skip-jira` label work. Without it, the label check has no data and falls through.

## Tests

Bats (helpers that mirror the workflow scripts):

```bash
bats .github/workflows/pr-hygiene/tests/test_allowlist.bats
```

End-to-end jobs live in [`test_pr-hygiene.yaml`](test_pr-hygiene.yaml) (also runs the bats suite). They call `reusable_pr-hygiene.yml` with a title and expect the job to succeed.

### End-to-end (`test_pr-hygiene.yaml`)

| Job                          | Input title                                                           | Asserts                                            |
| ---------------------------- | --------------------------------------------------------------------- | -------------------------------------------------- |
| `test-valid-title`           | `feat(workflows): [INFRA-378] add pr hygiene checks`                  | Scoped `feat` with Jira passes commitlint and Jira |
| `test-dependabot-allowed`    | `Build(deps): bump step-security/harden-runner from 2.14.0 to 2.14.2` | Default Dependabot allowlist (mixed-case type)     |
| `test-lowercase-dependabot`  | `build(deps): bump foo from 1.0.0 to 2.0.0`                           | Lowercase Dependabot allowlist                     |
| `test-stepsecurity-allowed`  | `[StepSecurity] Apply security best practices`                        | StepSecurity allowlist                             |
| `test-revert-allowed`        | `Revert "feat(workflows): [INFRA-370] add integration tests"`         | Git revert allowlist                               |
| `test-chore-no-jira`         | `chore: update readme`                                                | `chore` passes without a Jira ticket               |
| `test-breaking-change-title` | `feat!: [INFRA-649] Major release on breaking API changes`            | Breaking `feat!:` with Jira passes                 |
| `run-tests`                  | (n/a)                                                                 | Installs bats and runs `pr-hygiene/tests/`         |

### Bats (`tests/test_allowlist.bats`)

Helpers in `tests/helpers/setup.bash` reimplement allowlist matching, Jira extraction, type extraction, and the type gate. They are not the workflow YAML.

| Group             | Test                                                       | Asserts                                                    |
| ----------------- | ---------------------------------------------------------- | ---------------------------------------------------------- |
| Default allowlist | Dependabot title matches default pattern                   | `Build(deps): …` matches                                   |
| Default allowlist | Dependabot dev-deps title matches default pattern          | `Build(deps-dev): …` matches                               |
| Default allowlist | StepSecurity title matches default pattern                 | `[StepSecurity] …` matches                                 |
| Default allowlist | Revert with quotes matches default pattern                 | `Revert "…"` matches                                       |
| Default allowlist | lowercase revert matches default pattern                   | `revert: …` matches                                        |
| Default allowlist | lowercase build(deps) matches default pattern              | `build(deps): …` matches                                   |
| Default allowlist | chore(deps) matches default pattern                        | `chore(deps): …` matches                                   |
| Default allowlist | fix(deps-dev) matches default pattern                      | `fix(deps-dev): …` matches                                 |
| Non-matching      | conventional commit with JIRA does not match allowlist     | Normal `feat(scope): [KEY-n] …` is not allowlisted         |
| Non-matching      | plain text title does not match allowlist                  | `fix some bug` is not allowlisted                          |
| Non-matching      | partial pattern match at wrong position does not match     | `deps` not at start does not match                         |
| Non-matching      | empty title does not match allowlist                       | Empty string is not allowlisted                            |
| Non-matching      | Revert with single quotes does not match default pattern   | `Revert '…'` does not match `^[Rr]evert "`                 |
| Non-matching      | Build without deps scope does not match Dependabot pattern | `Build: …` does not match                                  |
| Non-matching      | empty patterns array matches nothing                       | No patterns → no match                                     |
| Custom patterns   | custom pattern matches when added                          | Extra `^chore\(release\):` matches `chore(release): 2.0.0` |
| Custom patterns   | custom pattern does not affect default rejections          | Extra pattern still rejects `feat: no jira ticket`         |
| Custom patterns   | custom-only patterns match when defaults are overridden    | `^my-bot:` matches `my-bot: …`                             |
| Custom patterns   | default titles rejected when patterns are overridden       | Dependabot title rejected if defaults dropped              |
| Jira extraction   | valid title extracts JIRA ticket                           | `feat(workflows): [INFRA-378] …` → `INFRA-378`             |
| Jira extraction   | breaking change title without scope extracts JIRA ticket   | `feat!: [INFRA-649] …` → `INFRA-649`                       |
| Jira extraction   | breaking change title with scope extracts JIRA ticket      | `feat(workflows)!: [INFRA-649] …` → `INFRA-649`            |
| Jira extraction   | missing JIRA ticket returns empty                          | `feat: missing jira ticket` → empty                        |
| Jira extraction   | JIRA without brackets returns empty                        | Bare `INFRA-123` → empty                                   |
| Commit type       | extract_commit_type returns feat from conventional commit  | `feat(workflows): …` → `feat`                              |
| Commit type       | extract_commit_type returns chore from scopeless commit    | `chore: …` → `chore`                                       |
| Type gate         | feat type requires JIRA with default types                 | `feat` is required                                         |
| Type gate         | fix type requires JIRA with default types                  | `fix` is required                                          |
| Type gate         | refactor type requires JIRA with default types             | Helper default list includes `refactor`                    |
| Type gate         | chore type does not require JIRA with default types        | `chore` is not required                                    |
| Type gate         | build type does not require JIRA with default types        | `build` is not required                                    |
| Type gate         | perf type does not require JIRA with default types         | `perf` is not required                                     |
| Type gate         | test type does not require JIRA with default types         | `test` is not required                                     |
| Type gate         | empty jira-required-types means JIRA never required        | Empty list → `feat` not required                           |
| Type gate         | custom jira-required-types list is respected               | `chore` required when list is `chore, test`                |
| Type gate         | type not in custom list does not require JIRA              | `feat` not required when list is `chore, test`             |
