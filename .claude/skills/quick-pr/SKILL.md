---
name: quick-pr
description: Draft a lightweight pull request for small, non-Jira changes
disable-model-invocation: true
---

<!-- markdownlint-disable MD041 -->

Draft a lightweight pull request for the current branch. Use this for small housekeeping changes (docs updates, dependency bumps, config tweaks, linting fixes) that don't have a Jira ticket.

## Instructions

1. Run `git branch --show-current` to get the current branch name.
2. Determine the base branch — use `main` unless the user specifies otherwise via $ARGUMENTS.
3. Run `git log` and `git diff` against the base branch to understand ALL changes (not just the latest commit).
4. Check if the branch has been pushed to the remote. If not, ask before pushing.
5. Draft the PR:
   - **Title**: Conventional commits format: `type(scope): description`
     - Determine the `type` by reviewing ALL commits on the branch and bubbling up to a single conventional commit type
     - Common types: `chore`, `docs`, `fix`, `refactor`, `ci`, `build`, `test`, `feat`, `perf`
     - `scope` is the area of the change (e.g., `docs`, `workflows`, `deps`, `actions`)
     - Keep under 70 characters total
     - Examples: `docs(cicd): update walkthrough for v3.2.0`, `chore(deps): bump actions/checkout to v6`
   - **Body**: Write it as a short narrative, not a formal template. Structure:

```markdown
## Summary

A brief paragraph (2-4 sentences) explaining what changed and why in plain language. Write it like you're explaining the change to a teammate — conversational but clear. Focus on the motivation and what's different, not a mechanical list of every file touched.

## Changes

- Concise list of the notable changes
- Group related changes on one line where it makes sense
- Skip trivial/obvious items (formatting, whitespace)

## Test plan

How to verify — or note if no testing is needed (e.g., "docs-only change").
```

6. Present the draft to the user for review before creating the PR.
7. Create using `gh pr create`.

## User arguments

If the user provides arguments, treat them as additional context about the PR (e.g., base branch, extra description, or specific focus areas).
$ARGUMENTS
