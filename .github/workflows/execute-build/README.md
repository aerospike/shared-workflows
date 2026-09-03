# Execute Build Workflow

> **Note:** This workflow is used internally by [`reusable_artifacts-cicd.yaml`](../artifacts-cicd/README.md). Most consumers should use the orchestrator rather than calling this directly.

Set up and build using an arbitrary build script and upload the results to be used later by other actions.

## Overview

This workflow executes a custom build script and uploads the resulting artifacts for use by other workflows. It provides a flexible way to run any build process while ensuring artifacts are properly captured and made available.

## Inputs

| Input                        | Description                                                                                                                                | Required | Default                         |
| ---------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ | -------- | ------------------------------- |
| `jf-project`                 | JFrog Artifactory project name                                                                                                             | Yes      | -                               |
| `jf-build-name`              | Name for this build in artifactory                                                                                                         | Yes      | -                               |
| `jf-build-id`                | Build ID for this build in artifactory                                                                                                     | Yes      | -                               |
| `build-script`               | Inline bash commands to execute                                                                                                            | No\*     | -                               |
| `build-script-path`          | Path to the build script file to execute                                                                                                   | No\*     | -                               |
| `gh-artifact-directory`      | Directory that will contain all artifacts from this build                                                                                  | Yes      | -                               |
| `gh-artifact-name`           | Name for the uploaded artifacts                                                                                                            | No       | `build-artifacts`               |
| `gh-retention-days`          | Retention days for the artifacts                                                                                                           | No       | `1`                             |
| `working-directory`          | Working directory for build script execution                                                                                               | No       | `.`                             |
| `jf-url`                     | JFrog Artifactory URL                                                                                                                      | No       | `https://artifact.aerospike.io` |
| `oidc-provider-name`         | OIDC provider name                                                                                                                         | No       | `gh-aerospike`                  |
| `oidc-audience`              | OIDC audience                                                                                                                              | No       | `aerospike`                     |
| `runs-on`                    | The runner to use for the build                                                                                                            | No       | `ubuntu-22.04`                  |
| `gh-checkout-path`           | Directory to checkout the shared-workflows repository into                                                                                 | No       | `shared-workflows`              |
| `gh-workflows-ref`           | Git ref for shared-workflows (**should match your `uses:` version**)                                                                       | Yes      | -                               |
| `gh-source-repository`       | Repository to checkout for source code (format owner/repo)                                                                                 | No       | `${{ github.repository }}`      |
| `gh-source-ref`              | Reference to checkout for source repository (branch, tag, or commit)                                                                       | No       | -                               |
| `gh-source-path`             | Directory to checkout the source repository into. If set to an empty string, the source repository is not checked out.                     | No       | `local`                         |
| `gh-source-app-client-id`    | Client ID of a GitHub App used to mint the source checkout token. See [Private source checkouts](#private-source-checkouts).               | No       | -                               |
| `gh-source-app-repositories` | Repositories the minted token may reach. Empty means every repository in the App installation.                                             | No       | -                               |
| `build-env`                  | Semicolon-delimited `KEY=VALUE` pairs exported to the build script. Use `\;` for a literal `;`, `\\` for a backslash.                      | No       | -                               |
| `matrix-json-data`           | JSON for the current matrix entry. Exported as `MATRIX_JSON` to the build subprocess. Set automatically by `reusable_artifacts-cicd.yaml`. | No       | -                               |
| `publish-build-info`         | Whether to publish build-info to JFrog                                                                                                     | No       | `true`                          |
| `setup-dotnet`               | Install the .NET SDK before the build script runs                                                                                          | No       | `false`                         |
| `dotnet-version`             | .NET SDK version (when `setup-dotnet`)                                                                                                     | No       | `"8.0"`                         |
| `setup-java`                 | Install Java before the build script runs                                                                                                  | No       | `false`                         |
| `java-version`               | Java version (when `setup-java`)                                                                                                           | No       | `"21"`                          |
| `java-distribution`          | Java distribution (when `setup-java`)                                                                                                      | No       | `temurin`                       |
| `java-cache`                 | Package manager to cache (when `setup-java`)                                                                                               | No       | `maven`                         |
| `setup-python`               | Install Python before the build script runs                                                                                                | No       | `false`                         |
| `python-version`             | Python version (when `setup-python`)                                                                                                       | No       | `"3.12"`                        |
| `setup-helm`                 | Install the Helm CLI before the build script runs                                                                                          | No       | `false`                         |
| `helm-version`               | Helm version (when `setup-helm`)                                                                                                           | No       | `latest`                        |
| `dry-run`                    | Whether to run in dry-run mode                                                                                                             | No       | `false`                         |

\*Either `build-script` or `build-script-path` is required, but not both.

## Example Usage

**Note**: The examples below show the pattern for external consumers using tagged versions. Internal workflows in this repository use relative paths (e.g., `uses: ./.github/workflows/reusable_execute-build.yaml`) for development and testing.

### Using inline build commands

```yaml
name: Build and Upload
on:
  workflow_dispatch:
  push:
    branches: [main]

jobs:
  build:
    uses: aerospike/shared-workflows/.github/workflows/reusable_execute-build.yaml@v3.2.0
    with:
      jf-project: my-project
      jf-build-name: my-app
      jf-build-id: 1234567890
      build-script: make clean && make all && cp build/* dist/
      gh-artifact-directory: dist
      gh-artifact-name: my-build-artifacts
      gh-retention-days: 7
      gh-workflows-ref: v3.2.0 # Should match the version in your 'uses:' line
      dry-run: false
```

### Using a build script file

```yaml
jobs:
  build:
    uses: aerospike/shared-workflows/.github/workflows/reusable_execute-build.yaml@v3.2.0
    with:
      jf-project: my-project
      jf-build-name: my-app
      jf-build-id: 1234567890
      build-script-path: ./scripts/build.sh
      gh-artifact-directory: dist
      gh-artifact-name: my-build-artifacts
      gh-retention-days: 7
      gh-workflows-ref: v3.2.0 # Should match the version in your 'uses:' line
      dry-run: false
```

## Required: gh-workflows-ref

The `gh-workflows-ref` input is **required** and must match the version in your `uses:` line. See [Why gh-workflows-ref is required](../docs/why-gh-workflows-ref.md) for details on this GitHub Actions limitation.

## Private source checkouts

The source checkout uses the calling repo's `GITHUB_TOKEN`, which reaches only that repo. If the
source repo's submodules or sibling repos are separate private repositories, supply a credential in
one of two forms.

**GitHub App**, which mints a short-lived token in the job:

```yaml
with:
  gh-source-app-client-id: ${{ vars.APP_CLIENT_ID }}
  gh-source-app-repositories: |
    my-service
    my-shared-lib
secrets:
  gh-source-app-private-key: ${{ secrets.APP_PRIVATE_KEY }}
```

Name the repositories. Leaving `gh-source-app-repositories` empty gives the token every repository
in the App installation. The mint requests `contents: read` only.

**Pre-minted token**, for callers without a GitHub App:

```yaml
secrets:
  gh-source-token: ${{ secrets.MY_CHECKOUT_TOKEN }}
```

Setting both forms fails the job. A token cannot be minted in one job and passed to this one:
GitHub skips a job output that may contain a secret, which is why the App form exists.

Either form is exported to the build script as `GH_SOURCE_TOKEN`, and the checkout does not persist
it into `.git/config`. Do not pass `GH_SOURCE_TOKEN` as a Docker build-arg. Build-args are recorded
in image history and in SLSA provenance, which are readable by anyone who can pull the image.

## Build Script Requirements

Your build script should:

- Be executable (the workflow will make it executable if needed)
- Create artifacts in the specified `gh-artifact-directory`
- Exit with code 0 on success, non-zero on failure
- Handle its own dependency installation

## Prerequisites

- Build script must exist in the repository (if using `build-script-path`)
- Build script should create artifacts in the specified directory
- No additional system dependencies (build script handles its own requirements)

## Reading the matrix entry from a build script

When invoked through `reusable_artifacts-cicd.yaml`, the orchestrator sets `matrix-json-data` to the current matrix entry. The build script can read it via `$MATRIX_JSON`:

```bash
export DISTRO=$(jq -r '.distro' <<<"$MATRIX_JSON")
export ARCH=$(jq -r '.arch'   <<<"$MATRIX_JSON")
```

## Testing

Run the test suite:

```bash
# build-env parser
bats .github/workflows/execute-build/tests/

# entrypoint script
.github/workflows/execute-build/test-entrypoint.sh
```

## Notes on packaging

Packages should adhere to [standard aerospike naming conventions](https://aerospike.atlassian.net/wiki/spaces/~745351144/pages/4464574503/Aerospike+Package+Naming+Guidelines)
