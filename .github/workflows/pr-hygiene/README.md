# PR Hygiene

Reusable workflow that validates PR titles against conventional commit format and optionally requires a JIRA ticket. Uses commitlint for format validation and custom logic for JIRA enforcement.

## PR Title Format

PR titles must follow conventional commit format:

```text
type(scope): [JIRA-123] description
```

- **type**: `feat|fix|refactor|docs|test|ci|chore|build|perf` (validated by commitlint)
- **scope**: optional, lowercase (e.g., `workflows`, `deploy`, `actions`)
- **JIRA**: uppercase project key in brackets, required for certain types (see `types-requiring-jira`)

Examples:

- `feat(workflows): [INFRA-370] add artifacts-cicd integration tests`
- `fix(deploy): [ENG-123] correct artifact routing logic`
- `chore: [INFRA-400] update dependencies`

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
    uses: aerospike/shared-workflows/.github/workflows/reusable_pr-hygiene.yml@<sha>
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

```yaml
name: PR Hygiene

on:
  pull_request:
    types: [opened, edited, synchronize, reopened]

permissions:
  contents: read

jobs:
  validate:
    uses: ./.github/workflows/reusable_pr-hygiene.yml
    with:
      pr_title: ${{ github.event.pull_request.title }}
      pr-labels: ${{ toJSON(github.event.pull_request.labels.*.name) }}
```

## Testing

### Bats tests (local)

Unit tests for allowlist pattern matching and JIRA extraction:

```bash
bats .github/workflows/pr-hygiene/tests/test_allowlist.bats
```

### End-to-end tests (CI)

The [`test_pr-hygiene.yaml`](test_pr-hygiene.yaml) workflow runs end-to-end tests via the reusable workflow (valid title, Dependabot, StepSecurity, revert titles, chore without JIRA).
