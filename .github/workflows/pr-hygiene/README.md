# Setup hygiene actions

In this folder you will find two actions; one for checking that PR titles start with a reference to a Jira ticket, and one that relies on that check to extract that Jira ticket and prepend it to the git commit message on merge or squash. I recommend using both on repos to improve the git history and commit hygiene.

The reason for having these is so that we can get strong automatic linking to the new Jira Deployments feature; which according to Atlassian support is the best way to make sure that linkage is granular and appropriate.

The command `git push --force-with-lease origin $BASE_REF` may raise concerns; the `--force-with-lease` option should make sure that no code can be over-written with it; it is intended to just modify the commit message with a prefix.

## PR Title Format

PR titles must follow conventional commit format with a JIRA ticket:

```text
type(scope): [JIRA-123] description
```

- **type**: `feat|fix|refactor|docs|test|ci|chore|build|perf` (validated by commitlint)
- **scope**: optional, lowercase (e.g., `workflows`, `deploy`, `actions`)
- **JIRA**: uppercase project key in brackets, before the description

Examples:

- `feat(workflows): [INFRA-370] add artifacts-cicd integration tests`
- `fix(deploy): [ENG-123] correct artifact routing logic`
- `chore: [INFRA-400] update dependencies`

## Example Usage

These are examples of actions that use the included workflows. Both are recommended.

### Example of workflow using hygiene check

How to use the hygiene workflow to check if a PR title includes a reference to a Jira ticket.

```yaml
name: PR Hygiene - Jira Ticket in Title

on:
  pull_request:
    types: [opened, edited, synchronize, reopened]

jobs:
  validate-jira-ticket:
    uses: ./.github/workflows/reusable_pr-hygiene.yml
    with:
      pr_title: ${{ github.event.pull_request.title }}
```

### Example of workflow using PR merge check

How to use the merge workflow to change a commit message to include the same Jira reference as the PR title if one is available.

```yaml
name: PR Squash and Merge - Prepend Jira ticket

on:
  push:
    branches:
      - main

jobs:
  merge-with-jira:
    runs-on: ubuntu-latest
    outputs:
      pr_title: ${{ steps.get-merged-pull-request.outputs.title }}
    steps:
      - uses: actions-ecosystem/action-get-merged-pull-request@59afe90821bb0b555082ce8ff1e36b03f91553d9 # v1.0.1
        id: get-merged-pull-request
        with:
          github_token: ${{ secrets.GITHUB_TOKEN }}
  call-merge-workflow:
    needs: merge-with-jira
    if: ${{ needs.merge-with-jira.outputs.pr_title != null }}
    uses: ./.github/workflows/reusable_pr-hygiene-merge.yml
    with:
      pr_title: ${{ needs.merge-with-jira.outputs.pr_title }}
      merge_commit_sha: ${{ github.event.pull_request.merge_commit_sha }}
      base_ref: ${{ github.event.pull_request.base.ref }}
    secrets:
      passed_github_token: ${{ secrets.GITHUB_TOKEN }}
```

## Local Testing with act

A test workflow is included at [`test_pr-hygiene.yaml`](test_pr-hygiene.yaml). It tests both the happy path (via the reusable workflow) and failure cases (commitlint rejection, missing JIRA, JIRA without brackets).

To run it locally using [`gh act`](https://github.com/nektos/gh-act):

```bash
# Copy the test workflow into place (act requires workflows in .github/workflows/)
cp .github/workflows/pr-hygiene/test_pr-hygiene.yaml .github/workflows/test_pr-hygiene.yaml

# Run the full test workflow
gh act pull_request -W .github/workflows/test_pr-hygiene.yaml

# Run just the failure case tests (faster, no reusable workflow call)
gh act pull_request -W .github/workflows/test_pr-hygiene.yaml -j test-failure-cases

# Clean up
rm .github/workflows/test_pr-hygiene.yaml
```

Note: `act` has limited support for `workflow_call` (reusable workflows), so the `test-valid-title` job may not work locally. The `test-failure-cases` job runs the validation logic directly and works reliably with `act`. To run the full end-to-end test, use `workflow_dispatch` from the GitHub Actions UI after copying the test workflow into `.github/workflows/`.
