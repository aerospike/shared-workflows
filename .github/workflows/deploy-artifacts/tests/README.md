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
  - `maven_fixtures.bash` - JFrog-layout Maven fixtures for structuring tests
  - `command_parsers.bash` - Command parsing utilities
  - `assertions.bash` - Validation assertions
- `maven-coverage-matrix.md` - Maven release shapes vs bats coverage table

## Test Files

### Unit tests (source functions directly, no entrypoint execution)

- `test_metadata.bats` - Metadata extraction: codename mapping, nupkg/rpm parsing
- `test_type_registry.bats` - Registry config, base/per-type props, known extensions
- `test_command_parsers.bats` - `extract_upload_commands` / `extract_nuget_commands` on dry-run-shaped lines (leading ANSI + spaces + `jf`, per `run()` in entrypoint)

### Structuring tests (verify file routing and companion co-location)

- `test_structuring.bats` - Artifact routing to correct dirs, companion gathering, prefix stripping, Windows → `win/` + `generic-dev-local` uploads, Rust `.crate` → `crate/` + `generic-dev-local`; Maven flat + nested GAV layout
- `test_maven_structuring.bats` - Maven detect_types + deploy structuring for jar+pom, parent+children, and pom-only (JFrog layout)
- `test_maven_bundle_metadata.bats` - `.maven-bundle-metadata.json` and detect-time standalone / reactor structuring

### Integration tests (dry-run entrypoint, parse upload commands)

- `test_deb_rpm_upload.bats` - DEB and RPM upload commands and target-props
- `test_java_upload.bats` - JAR/Maven artifact uploads
- `test_nupkg_upload.bats` - NuGet package uploads and metadata parsing
- `test_all_files_upload.bats` - JAR/generic routing and NuGet-not-in-generic safety check
- `test_crate_upload.bats` - Rust `.crate` validation, `crate/` structuring, generic-dev-local upload path, and `cargo.*` target-props
- `test_error_handling.bats` - Missing arguments and invalid options

### Regression tests (codify production bugs so they never regress)

- `test_bug_regressions.bats` - .asc signatures uploaded, no unsigned-artifacts prefix leak, generic gets version props
