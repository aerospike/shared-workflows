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
bats .github/workflows/deploy-artifacts/tests/bats/test_metadata.bats
```

## Test Structure

- `tests/bats/` - Test files (`.bats`)
- `tests/helpers/` - Helper functions:
  - `setup.bash` - Setup/teardown functions
  - `command_parsers.bash` - Command parsing utilities
  - `assertions.bash` - Validation assertions

## Test Files

### Unit tests (source functions directly, no entrypoint execution)

- `test_metadata.bats` - Metadata extraction: codename mapping, nupkg/rpm parsing
- `test_type_registry.bats` - Registry config, base/per-type props, known extensions

### Structuring tests (verify file routing and companion co-location)

- `test_structuring.bats` - Artifact routing to correct dirs, companion gathering, prefix stripping

### Integration tests (dry-run entrypoint, parse upload commands)

- `test_deb_rpm_upload.bats` - DEB and RPM upload commands and target-props
- `test_java_upload.bats` - JAR/Maven artifact uploads
- `test_nupkg_upload.bats` - NuGet package uploads and metadata parsing
- `test_all_files_upload.bats` - JAR/generic routing and NuGet-not-in-generic safety check
- `test_error_handling.bats` - Missing arguments and invalid options

### Regression tests (codify production bugs so they never regress)

- `test_bug_regressions.bats` - .asc signatures uploaded, no unsigned-artifacts prefix leak, generic gets version props
