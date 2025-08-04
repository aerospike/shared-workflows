# Build Artifacts Workflow

Set up and build using an arbitrary build script and upload the results to be used later by other actions.

## Overview

This workflow executes a custom build script and uploads the resulting artifacts for use by other workflows. It provides a flexible way to run any build process while ensuring artifacts are properly captured and made available.

## Inputs

| Input                | Description                                               | Required | Default           |
| -------------------- | --------------------------------------------------------- | -------- | ----------------- |
| `build-script`       | Path to the build script to execute                       | Yes      | -                 |
| `artifact-directory` | Directory that will contain all artifacts from this build | Yes      | -                 |
| `artifact-name`      | Name for the uploaded artifacts                           | No       | `build-artifacts` |
| `dry-run`            | Whether to run in dry-run mode                            | No       | `false`           |

## Example Usage

```yaml
name: Build and Upload
on:
  workflow_dispatch:
  push:
    branches: [main]

jobs:
  build:
    uses: ./.github/workflows/reusable_build-artifacts.yaml
    with:
      build-script: ./scripts/build.sh
      artifact-directory: dist
      artifact-name: my-build-artifacts
      dry-run: false
```

## Build Script Requirements

Your build script should:

- Be executable (the workflow will make it executable if needed)
- Create artifacts in the specified `artifact-directory`
- Exit with code 0 on success, non-zero on failure
- Handle its own dependency installation

Example build script:

```bash
#!/bin/bash
set -euo pipefail

echo "Starting build..."

# Your build commands here
make clean
make all

# Copy artifacts to the specified directory
mkdir -p "$1"  # artifact-directory is passed as first argument
cp build/*.tar.gz "$1/"
cp build/*.deb "$1/"

echo "Build completed successfully"
```

## Prerequisites

- Build script must exist in the repository
- Build script should create artifacts in the specified directory
- No additional system dependencies (build script handles its own requirements)

## Notes

- The workflow follows the established patterns from sign-artifacts and upload-artifacts workflows
- All operations support dry-run mode for testing
- The entrypoint script includes comprehensive error handling and logging
- Test suite provides detailed reporting with proper exit codes
- Artifacts are uploaded with 30-day retention by default
- Build script is automatically made executable if needed
- Workflow validates that artifacts were created after build completion

## Testing

Run the test suite:

```bash
.github/workflows/build-artifacts/test-entrypoint.sh
```

The test suite validates:

- Basic build script execution
- Dry-run mode functionality
- Error handling for missing scripts and arguments
- Help message display
- Script permission handling
- Artifact creation validation

The test suite will create temporary build scripts and verify all functionality works correctly.

## Error Handling

The workflow includes robust error handling:

- Validates build script exists before execution
- Makes scripts executable automatically if needed
- Verifies artifacts were created after build
- Provides clear error messages for common issues
- Supports dry-run mode for testing without side effects

## Integration

This workflow is designed to be used as a building block in larger CI/CD pipelines:

1. **Build Phase**: Use this workflow to execute your build process
2. **Test Phase**: Download artifacts and run tests
3. **Deploy Phase**: Download artifacts and deploy to environments

```yaml
jobs:
  build:
    uses: ./.github/workflows/reusable_build-artifacts.yaml
    with:
      build-script: ./build.sh
      artifact-directory: dist

  test:
    needs: build
    runs-on: ubuntu-latest
    steps:
      - uses: actions/download-artifact@v4
        with:
          name: build-artifacts
      - name: Run tests
        run: ./test.sh

  deploy:
    needs: [build, test]
    uses: ./.github/workflows/reusable_deploy.yaml
    with:
      artifact-name: build-artifacts
```
