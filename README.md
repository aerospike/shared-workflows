# Shared Workflows

This repository contains reusable GitHub Actions workflows for common CI/CD tasks.

## Available Workflows

### Sign Packages

- **File**: `.github/workflows/reusable_sign-artifacts.yaml`
- **Purpose**: Sign RPM, DEB, and NuGet packages with GPG and SSL.com certificates
- **Usage**: See [Sign Artifacts Documentation](#sign-artifacts)

### Upload Artifacts

- **File**: `.github/workflows/reusable_upload-artifacts.yaml`
- **Purpose**: Upload artifacts to various destinations
- **Usage**: See [Upload Artifacts Documentation](#upload-artifacts)

## Sign Artifacts

The reusable sign artifacts workflow signs RPM, DEB, and NuGet packages using GPG and SSL.com certificates. This workflow is designed to be called after a build workflow that produces packages as artifacts.

### Features

- **Multi-format support**: Signs RPM and DEB packages with GPG, optionally signs NuGet packages with SSL.com certificates
- **Automatic detection**: Automatically detects NuGet packages and signs them when enabled
- **Flexible configuration**: Supports custom artifact patterns, paths, and signing settings
- **Secure signing**: Uses GPG for RPM/DEB and SSL.com certificates for NuGet packages
- **Verification**: Includes built-in package verification steps

### Basic Usage

```yaml
name: Build and Sign My Packages

on:
  workflow_dispatch:
  push:
    branches: [main]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      # Your build steps here that produce packages
      - name: Build Packages
        run: |
          # Build RPM/DEB packages
          # Build NuGet packages
          dotnet pack --output artifacts

      - name: Upload Packages
        uses: actions/upload-artifact@v4
        with:
          name: packages
          path: artifacts/

  sign:
    needs: build
    uses: aerospike/shared-workflows/.github/workflows/reusable_sign-artifacts.yaml@main
    with:
      artifact-glob: artifacts/**/*.{deb,rpm,nupkg}
      enable-nuget-signing: true
    secrets:
      gpg-private-key: ${{ secrets.GPG_PRIVATE_KEY }}
      gpg-public-key: ${{ secrets.GPG_PUBLIC_KEY }}
      gpg-key-pass: ${{ secrets.GPG_KEY_PASS }}
      es-username: ${{ secrets.ES_USERNAME }}
      es-password: ${{ secrets.ES_PASSWORD }}
      credential-id: ${{ secrets.CREDENTIAL_ID }}
      es-totp-secret: ${{ secrets.ES_TOTP_SECRET }}
```

### Advanced Usage

```yaml
name: Build and Sign My Packages

on:
  workflow_dispatch:

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      # Your build steps here
      - name: Upload Packages
        uses: actions/upload-artifact@v4
        with:
          name: my-custom-packages
          path: dist/

  sign:
    needs: build
    uses: aerospike/shared-workflows/.github/workflows/reusable_sign-artifacts.yaml@main
    with:
      artifact-glob: dist/**/*.{deb,rpm,nupkg}
      output-dir: signed-packages
      retention-days: 30
      enable-nuget-signing: true
      nuget-environment: PROD
      jvm-max-memory: 2048M
    secrets:
      gpg-private-key: ${{ secrets.GPG_PRIVATE_KEY }}
      gpg-public-key: ${{ secrets.GPG_PUBLIC_KEY }}
      gpg-key-pass: ${{ secrets.GPG_KEY_PASS }}
      es-username: ${{ secrets.ES_USERNAME }}
      es-password: ${{ secrets.ES_PASSWORD }}
      credential-id: ${{ secrets.CREDENTIAL_ID }}
      es-totp-secret: ${{ secrets.ES_TOTP_SECRET }}
```

### Required Secrets

You need to set up the following secrets in your repository:

**For GPG signing (RPM/DEB packages):**

- `GPG_PRIVATE_KEY`: Your GPG private key
- `GPG_PUBLIC_KEY`: Your GPG public key
- `GPG_KEY_PASS`: Your GPG key passphrase

**For SSL.com signing (NuGet packages):**

- `ES_USERNAME`: Your SSL.com username
- `ES_PASSWORD`: Your SSL.com password
- `CREDENTIAL_ID`: Your SSL.com credential ID
- `ES_TOTP_SECRET`: Your SSL.com TOTP secret

### Input Parameters

| Parameter              | Description                               | Required | Default            |
| ---------------------- | ----------------------------------------- | -------- | ------------------ |
| `artifact-glob`        | Glob pattern to match artifacts to sign   | Yes      | -                  |
| `output-dir`           | Output directory for signed artifacts     | No       | `signed-artifacts` |
| `retention-days`       | Number of days to retain artifacts        | No       | `7`                |
| `enable-nuget-signing` | Enable SSL.com signing for NuGet packages | No       | `false`            |
| `nuget-environment`    | SSL.com environment for NuGet signing     | No       | `PROD`             |
| `jvm-max-memory`       | Maximum JVM memory for NuGet signing      | No       | `1024M`            |

### How It Works

1. **Download artifacts**: Downloads the specified artifacts containing packages
2. **GPG signing**: Signs RPM and DEB packages with GPG, creates detached signatures and checksums
3. **NuGet detection**: Automatically detects NuGet packages in the artifacts
4. **SSL.com signing**: Signs NuGet packages with SSL.com certificates (if enabled)
5. **Upload results**: Uploads all signed packages as artifacts
6. **Verify signatures**: Verifies signed packages and provides summaries

## Introduction

This repository is a centralized collection of reusable GitHub Actions and Workflows used across Aerospike repositories. It is public because many of the consuming repositories are public, and these workflows are intended to be widely reused.

## Repository Structure

We use the following layout for our actions and workflows:

```text
shared-workflows/
│
├── .github/
    ├── actions/
    │   └── <action-name>/
    │       ├── action.yaml
    │       └── README.md
    │
    └── workflows/
        ├── reusable_<name>.yaml           # ✅ Entry points for reusable workflows
        ├── test_<name>.yaml               # ✅ Workflow tests for reusable workflows
        └── <name>/                        # Supporting scripts and README per workflow
            ├── entrypoint.sh, test runners, etc.
            └── README.md
```

### Folder & File Roles

| Path                                | Purpose                                                       |
| ----------------------------------- | ------------------------------------------------------------- |
| `.github/actions/`                  | Composite GitHub Actions, each in its own directory           |
| `.github/workflows/reusable_*.yaml` | Reusable workflows (called via `workflow_call`)               |
| `.github/workflows/test_*.yaml`     | Test workflows that validate the reusable workflows           |
| `.github/workflows/<name>/`         | Shell scripts, test harnesses, and documentation per workflow |

### Naming Conventions

To simulate namespacing in a flat structure (since GitHub requires reusable workflows to be top-level `.yaml` files), we use the following prefixes:

- `reusable_`: workflows designed for reuse via `workflow_call`
- `test_`: workflows that test the (reusable) workflows in CI

This convention allows us to organize as we add more workflows and actions.
[!WARNING]

> Due to a [GitHub Actions platform limitation](https://github.com/orgs/community/discussions/18055), reusable workflow files must live **directly under `.github/workflows/`**.
> Nested workflows (e.g., `.github/workflows/some-folder/workflow.yaml`) **will not work** as `uses:` targets.

To work around this while maintaining some order we use a naming convention:

- All reusable `.yaml` workflows are prefixed with `reusable_` and placed at the root of `.github/workflows/`
- Supporting logic (e.g., `entrypoint.sh`, test scripts) lives in subfolders named after the workflow

## Versioning

GitHub Actions and Workflows in the same repository necessarily share a version. We will use semantic versioning (SemVer) to manage changes. Each release will be tagged in the repository.

### Consumer Versioning

We suggest that you pin these actions/workflows to a specific sha with a comment of the semver tag. This way you can use dependabot to keep your workflows up to date. See [dependabot.yml](.github/dependabot.yml) for an example of this.

```yaml
# ✅ GOOD
uses: aerospike/shared-workflows/actions/setup-gpg@ed780e9928d56ef074532dbc6877166d5460587a # v0.1.0
# pro: reproducible builds, allows you to specify a known version of the action
# pro: dependabot can auto-PR updates to your repo, will also update version comment
# pro: official GitHub security hardening best practice

# ❌ BAD
uses: aerospike/shared-workflows/actions/setup-gpg@v0.1.0
# pro: dependabot can auto-PR updates to your repo
# con: tags are not immutable. 'semver' hint not usable with semver niceties (pessimistic versioning, etc)

# ❌ BAD
uses: aerospike/shared-workflows/actions/setup-gpg@main
# con: unsupported versioning usage: if this breaks for you, you will be told you should've pinned to a sha
# con: Requires that main is always backwards compatible and never breaks anything ever (not possible)
# con: Requires extreme coordination with every consumer when updates are necessary (not going to do)
# pro: no updates ever needed in your repo!
```

### Major/Breaking Changes

If you need to introduce a major/breaking change in a specific action or workflow, that may indicate that we should move it to a different repo.

## Usage

To use a workflow or action from this repository, reference it in your GitHub repository's workflow file. For example:

```yaml
uses: aerospike/shared-workflows/workflows/workflow-1@ed780e9928d56ef074532dbc6877166d5460587a # v0.1.0
```

## Contributing

While we welcome contributions from the community, that isn't the intended use case for this repository. We'll try our best but may not respond to your issue or PR. We may close an issue or PR without much feedback.

## Repo Tooling

Linting will be run on PRs; you can save yourself some time and annoyance by linting as you write.

If you use Visual Studio Code or a derivative, there are suggested extensions in the [.vscode](.vscode) directory. You're highly encouraged to use these extensions or similar tools in your editor of choice.

### Trunk

Trunk can also be run as a CLI. Once installed, you can run `trunk git-hooks sync` to check and make sure that your code will pass CI.

### Linter notes

`kennylong.kubernetes-yaml-formatter`: Prettier and this yaml formatter disagree on some rules. If you have yaml format-on-save enabled with kennylong's extension, `trunk check|fmt` will complain about it.

`streetsidesoftware.code-spell-checker`: This isn't enabled via trunk and you should run it in your editor of choice. Trunk marks all misspelled words as errors, when they should properly be be notes (blue squiggles, not red squiggles).
