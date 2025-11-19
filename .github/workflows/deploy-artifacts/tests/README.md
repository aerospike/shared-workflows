# Bats Tests for deploy-artifacts

This directory contains bats tests for the deploy-artifacts entrypoint script.

## Prerequisites

- `bats` - Bash Automated Testing System
- `dpkg-deb` - For DEB package metadata extraction
- `rpm` - For RPM package metadata extraction

## Installing Bats

```bash
# Install Node.js/npm if not already installed

# Install bats
sudo npm install -g bats
```

## Running Tests

From the repository root:

```bash
# Run all tests
bats .github/workflows/deploy-artifacts/tests/bats/

# Run a specific test file
bats .github/workflows/deploy-artifacts/tests/bats/test_deb_rpm_upload.bats
bats .github/workflows/deploy-artifacts/tests/bats/test_error_handling.bats
bats .github/workflows/deploy-artifacts/tests/bats/test_nupkg_upload.bats
```

## Test Structure

- `tests/bats/` - Test files (`.bats`)
- `tests/helpers/` - Helper functions:
  - `setup.bash` - Setup/teardown functions
  - `command_parsers.bash` - Command parsing utilities
  - `assertions.bash` - validation assertions

## Test Files

- `test_deb_rpm_upload.bats` - Validates DEB and RPM upload commands with validation
- `test_all_files_upload.bats` - Validates generic file uploads (JAR, ZIP, TAR.GZ)
- `test_error_handling.bats` - Tests error handling for missing arguments
- `test_structured_artifacts.bats` - Tests processing messages and directory structure
- `test_nupkg_upload.bats` - Validates NuGet package uploads
- `test_java_upload.bats` - Validates Java artifact uploads

## What Gets Tested

The tests perform **validation** of commands, not just counting:

- File paths match expected test fixtures
- Repository names are correct (`test-project-{deb|rpm|generic|nupkg}-dev-local`)
- Build metadata (build-name, build-number, project) is correct
- Target-props format and values are validated
- `--flat=false` is present
- For DEB: `--deb` path format is validated
- For RPM: `rpm.distribution` and `rpm.architecture` props are validated
