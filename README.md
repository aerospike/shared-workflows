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

- **actions/**: Contains individual GitHub Actions.
- **workflows/**: Contains reusable GitHub Workflows.
- **docs/**: Documentation for each action and workflow.

## Versioning

GitHub Actions and Workflows in the same repository necessarily share a version. We will use semantic versioning (SemVer) to manage changes. Each release will be tagged in the repository.

We suggest that you not pin these actions/workflows to a specific sha in your repo and instead use the semver tag; this way you can use dependabot to keep your workflows up to date.

### Major/Breaking Changes

If you need to introduce a major/breaking change in a specific action or workflow, that may indicate that we should move it to a different repo.

## Usage

To use a workflow or action from this repository, reference it in your GitHub repository's workflow file. For example:

```yaml
uses: aerospike/shared-workflows/workflows/workflow-1@v1.0.0
```

## Contributing

While we welcome contributions from the community, that isn't the intended use case for this repository. We'll try our best but may not respond to your issue or PR. We may close an issue or PR without much feedback.

## Editor Tooling

Linting will be run on PRs; you can save yourself some time and annoyance by linting as you write.

If you use Visual Studio Code or a derivative, there are suggested extensions in the [.vscode](.vscode) directory. You're highly encouraged to use these extensions or similar tools in your editor of choice. Trunk in particular can be run without IDE integration before committing: `trunk fmt` will match what CI expects.

### Linter notes

`kennylong.kubernetes-yaml-formatter`: Prettier and this yaml formatter disagree on some rules. If you have yaml format-on-save enabled with kennylong's extension, `trunk check|fmt` will complain about it.

`streetsidesoftware.code-spell-checker`: This isn't enabled via trunk and you should run it in your editor of choice. Trunk marks all mispelled words as errors, when they should properly be be notes (blue squiggles, not red squiggles).
