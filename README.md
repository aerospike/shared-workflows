# shared-workflows

## Introduction

This repository is a centralized location for sharing GitHub Actions and Workflows across Aerospike repos. Because we have many public repos, this repo is also public.

## Repository Structure

To maintain organization and ease of use, we use the following directory layout:

```text
shared-workflows/
│
├── .github/
│   ├── actions/
│   │   ├── action-1/
|   |   |   ├── action1.yaml
|   |   |   ├── README.md
│   │   ├── action-2/
|   |   |   ├── action2.yaml
|   |   |   ├── README.md
│   │   └── ...
│   │
│   └── workflows/
│       ├── workflow-1/
│       │   ├── README.md
│       │   ├── workflow1.yaml
│       ├── workflow-2/
│       │   ├── README.md
│       │   ├── workflow2.yaml
│       └── ...

```

- **actions/**: Contains individual GitHub Actions. Each action should be in a folder named to describe its purpose (e.g., `setup-gpg`, `docker-build`).
- **workflows/**: Contains reusable GitHub Workflows. Each workflow should be in a folder named to describe its purpose (e.g., `security-scan`, `release-management`).
- **docs/**: Documentation for each action and workflow.

**Important**: While the example above uses generic names (`workflow-1`, `action-1`), in practice, folder names should be descriptive and indicate the purpose of the workflow or action they contain. For example, a security scanning workflow might be in a folder named `security-scan`, and a GPG setup action might be in a folder named `setup-gpg`. The folder name should help users understand what the workflow or action does at a glance.

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
