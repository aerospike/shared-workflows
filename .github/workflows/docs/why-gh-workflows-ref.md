# Why gh-workflows-ref is required

All shared workflows require the `gh-workflows-ref` input, which **should match** the version in your `uses:` line:

```yaml
jobs:
  build:
    uses: aerospike/shared-workflows/.github/workflows/reusable_execute-build.yaml@v3.3.0
    with:
      gh-workflows-ref: v3.3.0 # Should match @v3.3.0 above
      # ... other inputs ...
```

## The problem

GitHub Actions has a fundamental limitation: **reusable workflows cannot access their own ref**. When you call `uses: org/repo/.github/workflows/workflow.yaml@v3.3.0`, the workflow itself has no way to know it was called with `@v3.3.0`.

The available context variables don't help:

- `github.sha` → SHA of the _caller's_ commit, not shared-workflows
- `github.workflow_sha` → SHA of the _caller's_ workflow file, not the reusable one
- `github.ref` → ref of the _caller's_ repository

There is no `github.called_workflow_ref` or similar.

## Why this matters

These workflows need to checkout their own repository to access entrypoint scripts (bash scripts that do the actual work). Without knowing which version was called, they can't checkout the matching scripts, which leads to version mismatches where the workflow is v3.3.0 but the scripts are from a different version.

## Known issue

This is a long-standing GitHub Actions limitation with no native solution:

- [actions/runner#2417](https://github.com/actions/runner/issues/2417)
- [community/discussions#38659](https://github.com/orgs/community/discussions/38659)

Third-party workarounds exist but don't pass security review. Until GitHub adds native support, `gh-workflows-ref` is the reliable solution.
