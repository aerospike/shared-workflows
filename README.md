# Shared Workflows

This repository contains reusable GitHub Actions workflows for common CI/CD tasks.

## Available Workflows

### Sign Artifacts
- **File**: `.github/workflows/reusable_sign-artifacts.yaml`
- **Purpose**: Sign RPM and DEB packages with GPG
- **Usage**: See [Sign Artifacts Documentation](#sign-artifacts)

### Sign NuGet Packages
- **File**: `.github/workflows/reusable_sign-nuget.yaml`
- **Purpose**: Sign NuGet packages with SSL.com certificates
- **Usage**: See [Sign NuGet Packages Documentation](#sign-nuget-packages)

### Upload Artifacts
- **File**: `.github/workflows/reusable_upload-artifacts.yaml`
- **Purpose**: Upload artifacts to various destinations
- **Usage**: See [Upload Artifacts Documentation](#upload-artifacts)

## Sign NuGet Packages

The reusable NuGet signing workflow automatically detects .csproj files in your repository and signs the resulting NuGet packages using SSL.com certificates.

### Features

- **Auto-detection**: Automatically finds .csproj files and extracts package information
- **Flexible configuration**: Supports custom project paths, package names, and build settings
- **Secure signing**: Uses SSL.com certificates for professional code signing
- **Verification**: Includes built-in package verification steps

### Basic Usage

```yaml
name: Sign My NuGet Package

on:
  workflow_dispatch:
  push:
    branches: [main]

jobs:
  sign-nuget:
    uses: aerospike/shared-workflows/.github/workflows/reusable_sign-nuget.yaml@main
    secrets:
      ssl-username: ${{ secrets.SSL_USERNAME }}
      ssl-password: ${{ secrets.SSL_PASSWORD }}
      ssl-credential-id: ${{ secrets.SSL_CREDENTIAL_ID }}
      ssl-totp-secret: ${{ secrets.SSL_TOTP_SECRET }}
      ssl-client-id: ${{ secrets.SSL_CLIENT_ID }}
```

### Advanced Usage

```yaml
name: Sign My NuGet Package

on:
  workflow_dispatch:

jobs:
  sign-nuget:
    uses: aerospike/shared-workflows/.github/workflows/reusable_sign-nuget.yaml@main
    with:
      # Specify a specific .csproj file (optional)
      project-path: 'src/MyProject/MyProject.csproj'
      
      # Specify custom package name (optional)
      package-name: 'MyCustomPackage.2.1.0.nupkg'
      
      # Customize output directory
      output-dir: 'signed-packages'
      
      # Customize retention period
      retention-days: 90
      
      # Specify .NET version
      dotnet-version: '8.0.x'
      
      # Specify build configuration
      build-configuration: 'Release'
    secrets:
      ssl-username: ${{ secrets.SSL_USERNAME }}
      ssl-password: ${{ secrets.SSL_PASSWORD }}
      ssl-credential-id: ${{ secrets.SSL_CREDENTIAL_ID }}
      ssl-totp-secret: ${{ secrets.SSL_TOTP_SECRET }}
      ssl-client-id: ${{ secrets.SSL_CLIENT_ID }}
```

### Required Secrets

You need to set up the following secrets in your repository:

- `SSL_USERNAME`: Your SSL.com username
- `SSL_PASSWORD`: Your SSL.com password
- `SSL_CREDENTIAL_ID`: Your SSL.com credential ID
- `SSL_TOTP_SECRET`: Your SSL.com TOTP secret
- `SSL_CLIENT_ID`: Your SSL.com client ID

### How It Works

1. **Auto-detection**: The workflow automatically finds .csproj files in your repository
2. **Package extraction**: Extracts package name and version from the .csproj file
3. **Build**: Restores dependencies, builds the project, and creates the NuGet package
4. **Signing**: Signs the package using SSL.com certificates
5. **Verification**: Verifies the signed package and uploads it as an artifact

### Supported .csproj Properties

The workflow automatically extracts these properties from your .csproj file:

- `<PackageId>`: The package name (preferred)
- `<AssemblyName>`: Fallback for package name
- `<Version>`: The package version

If these properties are not found, the workflow uses sensible defaults.

# shared-workflows

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
# GOOD
uses: aerospike/shared-workflows/actions/setup-gpg@ed780e9928d56ef074532dbc6877166d5460587a # v0.1.0
# pro: reproducible builds, allows you to specify a known version of the action
# pro: dependabot can auto-PR updates to your repo, will also update version comment
# pro: official GitHub security hardening best practice

# BAD
uses: aerospike/shared-workflows/actions/setup-gpg@v0.1.0
# pro: dependabot can auto-PR updates to your repo
# con: tags are not immutable. 'semver' hint not usable with semver niceties (pessimistic versioning, etc)

# BAD
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
