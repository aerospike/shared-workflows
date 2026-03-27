# Create Release Bundle

Create a JFrog release bundle from one or more builds. Wraps the `create-release-bundle/entrypoint.sh` script.

## Prerequisites

- JFrog CLI must be configured before calling this action (via `setup-jfrog-cli`).
- The entrypoint script must be available on disk. Either checkout the full repo or use sparse-checkout to include `.github/workflows/create-release-bundle/`.

## Inputs

| Input             | Required | Default                                                 | Description                          |
| ----------------- | -------- | ------------------------------------------------------- | ------------------------------------ |
| `build-names`     | Yes      |                                                         | Comma-separated `name:version` pairs |
| `bundle-name`     | Yes      |                                                         | Release bundle name                  |
| `version`         | Yes      |                                                         | Release bundle version               |
| `jf-project`      | Yes      |                                                         | JFrog project key                    |
| `dry-run`         | No       | `false`                                                 | Run without creating the bundle      |
| `entrypoint-path` | No       | `.github/workflows/create-release-bundle/entrypoint.sh` | Path to the entrypoint script        |

## Example Usage

```yaml
steps:
  - uses: actions/checkout@v4
    with:
      sparse-checkout: |
        .github/actions
        .github/workflows/create-release-bundle
      sparse-checkout-cone-mode: false
  - uses: step-security/setup-jfrog-cli@v4
    env:
      JF_URL: https://artifact.aerospike.io
      JF_PROJECT: my-project
    with:
      oidc-provider-name: gh-aerospike
      oidc-audience: aerospike
  - uses: aerospike/shared-workflows/.github/actions/create-release-bundle@v3
    with:
      build-names: my-app:1.2.3,my-container:1.2.3
      bundle-name: my-release
      version: 1.2.3
      jf-project: my-project
```

## Combining All Three Bundle Actions

For the full lifecycle (delete, create, promote) in a single job, see the [example composable matrix workflow](../../workflows/example_composable-matrix.yaml).
