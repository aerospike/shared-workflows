# Execute Build Workflow

Set up and build using an arbitrary build script and upload the results to be used later by other actions.

## Overview

This workflow executes a custom build script and uploads the resulting artifacts for use by other workflows. It provides a flexible way to run any build process while ensuring artifacts are properly captured and made available.

## Inputs

| Input                            | Description                                                          | Required | Default                      |
| -------------------------------- | -------------------------------------------------------------------- | -------- | ---------------------------- |
| `project`                        | JFrog Artifactory project name                                       | Yes      | -                            |
| `build-name`                     | Name for this build in artifactory                                   | Yes      | -                            |
| `build-version`                  | Version for this build in artifactory                                | Yes      | -                            |
| `build-script`                   | Inline bash commands to execute                                      | No\*     | -                            |
| `build-script-path`              | Path to the build script file to execute                             | No\*     | -                            |
| `artifact-directory`             | Directory that will contain all artifacts from this build            | Yes      | -                            |
| `artifact-name`                  | Name for the uploaded artifacts                                      | No       | `build-artifacts`            |
| `retention-days`                 | Retention days for the artifacts                                     | No       | `1`                          |
| `artifactory-url`                | JFrog Artifactory URL                                                | No       | `https://aerospike.jfrog.io` |
| `artifactory-oidc-provider-name` | OIDC provider name                                                   | No       | `gh-aerospike`               |
| `artifactory-oidc-audience`      | OIDC audience                                                        | No       | `aerospike`                  |
| `runs-on`                        | The runner to use for the build                                      | No       | `ubuntu-22.04`               |
| `checkout-path`                  | Directory to checkout the shared-workflows repository into           | No       | `shared-workflows`           |
| `source-repository`              | Repository to checkout for source code (format owner/repo)           | No       | -                            |
| `source-ref`                     | Reference to checkout for source repository (branch, tag, or commit) | No       | -                            |
| `source-path`                    | Directory to checkout the source repository into                     | No       | `.`                          |
| `dry-run`                        | Whether to run in dry-run mode                                       | No       | `false`                      |

\*Either `build-script` or `build-script-path` is required, but not both.

## Example Usage

### Using inline build commands

```yaml
name: Build and Upload
on:
  workflow_dispatch:
  push:
    branches: [main]

jobs:
  build:
    uses: aerospike/shared-workflows/.github/workflows/reusable_execute-build.yaml
    with:
      project: my-project
      build-name: my-app
      build-version: v1.0.0
      build-script: make clean && make all && cp build/* dist/
      artifact-directory: dist
      artifact-name: my-build-artifacts
      retention-days: 7
      dry-run: false
```

### Using a build script file

```yaml
jobs:
  build:
    uses: aerospike/shared-workflows/.github/workflows/reusable_execute-build.yaml
    with:
      project: my-project
      build-name: my-app
      build-version: v1.0.0
      build-script-path: ./scripts/build.sh
      artifact-directory: dist
      artifact-name: my-build-artifacts
      retention-days: 7
      dry-run: false
```

## Build Script Requirements

Your build script should:

- Be executable (the workflow will make it executable if needed)
- Create artifacts in the specified `artifact-directory`
- Exit with code 0 on success, non-zero on failure
- Handle its own dependency installation

## Prerequisites

- Build script must exist in the repository (if using `build-script-path`)
- Build script should create artifacts in the specified directory
- No additional system dependencies (build script handles its own requirements)

## Testing

Run the test suite:

```bash
.github/workflows/execute-build/test-entrypoint.sh
```

## Notes on packaging

Packages should adhere to [standard aerospike naming conventions](https://aerospike.atlassian.net/wiki/spaces/~745351144/pages/4464574503/Aerospike+Package+Naming+Guidelines)
