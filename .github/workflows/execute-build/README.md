# Execute Build Workflow

Set up and build using an arbitrary build script and upload the results to be used later by other actions.

## Overview

This workflow executes a custom build script and uploads the resulting artifacts for use by other workflows. It provides a flexible way to run any build process while ensuring artifacts are properly captured and made available.

## Inputs

| Input                | Description                                               | Required | Default           |
| -------------------- | --------------------------------------------------------- | -------- | ----------------- |
| `build-script`       | Inline bash commands to execute                           | No\*     | -                 |
| `build-script-path`  | Path to the build script file to execute                  | No\*     | -                 |
| `artifact-directory` | Directory that will contain all artifacts from this build | Yes      | -                 |
| `artifact-name`      | Name for the uploaded artifacts                           | No       | `build-artifacts` |
| `retention-days`     | Retention days for the artifacts                          | No       | `1`               |
| `dry-run`            | Whether to run in dry-run mode                            | No       | `false`           |

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
    uses: ./.github/workflows/reusable_execute-build.yaml
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
    uses: ./.github/workflows/reusable_execute-build.yaml
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

### Example build script file

```bash
#!/bin/bash
set -euo pipefail

echo "Starting build..."

# Your build commands here
make clean
make all

# Copy artifacts to the specified directory
mkdir -p build-output
cp build/*.tar.gz build-output/
cp build/*.deb build-output/

echo "Build completed successfully"
```

### Example inline build commands

```bash
# These commands will be executed directly
make clean && make all && mkdir -p dist && cp build/* dist/
```

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
