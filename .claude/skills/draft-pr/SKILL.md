---
name: draft-pr
description: Draft a pull request with Jira linking from the branch name
disable-model-invocation: true
---

<!-- markdownlint-disable MD041 -->

Draft a pull request for the current branch.

## Instructions

1. Run `git branch --show-current` to get the current branch name.
2. Extract the Jira ticket key if present (pattern: uppercase letters + hyphen + digits, e.g., INFRA-370, ENG-123). The ticket may appear anywhere in the branch name.
3. Determine the base branch — use `main` unless the user specifies otherwise via $ARGUMENTS.
4. Run `git log` and `git diff` against the base branch to understand ALL changes (not just the latest commit).
5. Check if the branch has been pushed to the remote. If not, ask before pushing.
6. Draft the PR:
   - **Title**: Must follow conventional commits format: `type(context): [JIRA] description`
     - Determine the `type` by reviewing ALL commits on the branch and bubbling up to a single conventional commit type (e.g., if commits include `feat` and `fix`, use `feat` since it's the higher-level change)
     - Common types: `feat`, `fix`, `refactor`, `docs`, `test`, `ci`, `chore`, `build`, `perf`
     - `context` is the area/scope of the change (e.g., `workflows`, `actions`, `deploy`)
     - `[JIRA]` is the Jira ticket key in brackets if found (e.g., `[INFRA-370]`)
     - Keep under 70 characters total
     - Examples: `feat(workflows): [INFRA-370] add artifacts-cicd integration tests`, `fix(deploy): [ENG-123] correct artifact routing logic`
   - **Body** using this structure:

<!-- prettier-ignore -->
```markdown
## Summary
<1-3 bullet points summarizing what changed and why>

## Jira
<link to ticket if found, otherwise omit this section>

## Changes
<Bulleted list of specific changes, grouped by area if needed>

## Test plan
<How to verify these changes — mention any tests added/run>
```

7. Present the draft to the user for review before creating the PR.
8. Create using `gh pr create`.

## Jira URL

Construct Jira links as: <https://aerospike.atlassian.net/browse/{TICKET_KEY}>

## User arguments

If the user provides arguments, treat them as additional context about the PR (e.g., base branch, extra description, or ticket details).
$ARGUMENTS
