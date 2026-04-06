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
        ├── reusable_<name>.yaml           #  Entry points for reusable workflows
        ├── test_<name>.yaml               #  Workflow tests for reusable workflows
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
| `.github/workflows/<name>/*`        | Shell scripts, test harnesses, and documentation per workflow |

### Naming Conventions

To simulate namespacing in a flat structure (since GitHub requires reusable workflows to be top-level `.yaml` files), we use the following prefixes:

- `reusable_`: workflows designed for reuse via `workflow_call`
- `test_`: workflows that test the (reusable) workflows in CI
- `example_`: workflows that give a working example of how to use other workflows

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

## Workflows & Actions

### CI/CD Workflows

For CI/CD pipelines, see the [CI/CD standard](.github/workflows/docs/CICD-standard.md) for quickstart guidance.

| Workflow                              | Purpose                                                               | Docs                                                        |
| ------------------------------------- | --------------------------------------------------------------------- | ----------------------------------------------------------- |
| `reusable_artifacts-cicd.yaml`        | Artifacts pipeline — build → sign → deploy (DEB, RPM, NuGet, generic) | [README](.github/workflows/artifacts-cicd/README.md)        |
| `reusable_docker-build-deploy.yaml`   | Docker pipeline — multi-arch OCI images with SLSA attestations        | [README](.github/workflows/docker-build-deploy/README.md)   |
| `reusable_create-release-bundle.yaml` | Release bundles — combine artifact + docker outputs                   | [README](.github/workflows/create-release-bundle/README.md) |
| `reusable_execute-build.yaml`         | Run arbitrary build script, upload artifacts                          | [README](.github/workflows/execute-build/README.md)         |
| `reusable_sign-artifacts.yaml`        | GPG sign deb/rpm/generic, SSL.com sign nupkg                          | [README](.github/workflows/sign-artifacts/README.md)        |
| `reusable_deploy-artifacts.yaml`      | Upload to JFrog Artifactory (auto-routes by type)                     | [README](.github/workflows/deploy-artifacts/README.md)      |

### Other Workflows & Actions

| Workflow / Action            | Purpose                                         | Docs                                               |
| ---------------------------- | ----------------------------------------------- | -------------------------------------------------- |
| `reusable_pr-hygiene.yml`    | PR title Jira check + commit message prepend    | [README](.github/workflows/pr-hygiene/README.md)   |
| `reusable_anchore-scan.yaml` | Security scanning with GitHub Advanced Security | [README](.github/workflows/anchore-scan/README.md) |
| `actions/setup-gpg`          | Composite action to configure GPG signing       | [README](.github/actions/setup-gpg/README.md)      |

## Usage

Reference workflows in your GitHub Actions workflow file:

```yaml
uses: aerospike/shared-workflows/.github/workflows/reusable_artifacts-cicd.yaml@<sha> # v2.0.3
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
