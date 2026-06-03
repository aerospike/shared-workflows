# PR Hygiene

Reusable workflow that validates PR titles against conventional commit format and optionally requires a JIRA ticket. Uses commitlint for format validation and custom logic for JIRA enforcement.

## PR Title Format

PR titles must follow conventional commit format:

```text
type(scope): [JIRA-123] description
```

- **type**: `feat|fix|refactor|docs|test|ci|chore|build|perf` (validated by commitlint)
- **scope**: optional, lowercase alphanumeric with hyphens and underscores (e.g., `workflows`, `deploy`, `actions`, `my-scope`, `my_scope`)
- **JIRA**: uppercase project key in brackets, required for certain types (see [Types and Jira enforcement](#types-and-jira-enforcement))

Examples:

- `feat(workflows): [INFRA-370] add artifacts-cicd integration tests`
- `fix(deploy): [ENG-123] correct artifact routing logic`
- `chore: update dependencies`

## Types and Jira enforcement

Not every commit type needs a Jira ticket. The defaults split `feat|fix|refactor|docs|test|ci|chore|build|perf` into two groups, based on whether the change should be traceable back to a planned work item.

| Commit type                             | Jira ticket  |
| --------------------------------------- | ------------ |
| `feat`, `fix`, `refactor`, `docs`, `ci` | **Required** |
| `chore`, `build`, `test`, `perf`        | Optional     |

Required types correspond to user-visible or traceable work: new features, bug fixes, meaningful refactors, published docs, and CI changes that affect how the project is built or released. Optional types cover housekeeping, dependency bumps, internal tests, and performance tuning that often lacks a dedicated ticket.

Override with the `types-requiring-jira` input to narrow, expand, or disable Jira enforcement for your repo. Setting it to the empty string disables Jira enforcement entirely.

## Bypassing Jira enforcement

Sometimes a required-type PR legitimately has no Jira ticket (an urgent fix, an externally driven change, a cleanup merged during a freeze). Two bypass mechanisms are available, in priority order:

1. **The `skip-jira` label.** Add the `skip-jira` label to the PR (name configurable via `skip-jira-label`). Commitlint still runs, but the Jira ticket requirement is skipped. The caller must also pass the PR's labels via `pr-labels` for the label check to work. See the [example](#example-usage) below.
2. **The [allowlist](#allowlist-for-automated-prs).** If the PR title matches one of the `allowed-patterns` regexes, both commitlint and Jira validation are skipped. Use this for bot-generated PRs and other predictable title shapes, not for one-off human overrides.

## Allowlist for Automated PRs

The hygiene workflow includes an allowlist that lets certain PR titles bypass both commitlint and JIRA validation. This is useful for automated PRs from bots and standard git operations.

### Default Patterns

The `allowed-patterns` input ships with these defaults:

| Pattern                    | Matches                                |
| -------------------------- | -------------------------------------- |
| `^[a-zA-Z]+\(deps[^)]*\):` | Dependabot dependency bumps (any type) |
| `^\[StepSecurity\]`        | StepSecurity bot PRs                   |
| `^[Rr]evert "`             | Git revert commits                     |
| `^revert:`                 | Conventional commit reverts            |
| `^Bump`                    | Dependency bump                        |

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
        ^chore\(release\):
        ^Bump version to
```

To use only your own patterns, override `allowed-patterns` entirely:

```yaml
with:
  pr_title: ${{ github.event.pull_request.title }}
  allowed-patterns: |
    ^my-custom-pattern
```

## Inputs

| Input                  | Required | Default                                | Description                                                                                                                   |
| ---------------------- | -------- | -------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `pr_title`             | Yes      |                                        | PR title to validate                                                                                                          |
| `allowed-patterns`     | No       | Dependabot, StepSecurity, revert, Bump | Newline-delimited regex patterns (ERE). Matching titles bypass all validation.                                                |
| `types-requiring-jira` | No       | `feat, fix, docs, ci, refactor`        | Comma-separated conventional commit types that require a JIRA ticket. Set to empty string to never require JIRA.              |
| `skip-jira-label`      | No       | `skip-jira`                            | PR label that bypasses JIRA validation. Commitlint still runs.                                                                |
| `pr-labels`            | No       | `""`                                   | JSON array of PR label names (from `toJSON(github.event.pull_request.labels.*.name)`). Used to check for the skip-jira label. |

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

Passing `pr-labels` is what lets the `skip-jira` label bypass work. Without it, the label check has no data and falls through.

## Testing

### Bats tests (local)

Unit tests for allowlist pattern matching and JIRA extraction:

```bash
bats .github/workflows/pr-hygiene/tests/test_allowlist.bats
```

### End-to-end tests (CI)

The [`test_pr-hygiene.yaml`](test_pr-hygiene.yaml) workflow runs end-to-end tests via the reusable workflow (valid title, Dependabot, StepSecurity, revert titles, chore without JIRA).
