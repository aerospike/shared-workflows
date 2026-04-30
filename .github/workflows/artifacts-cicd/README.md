# Artifacts CI/CD (Reusable Workflow)

This workflow orchestrates the standard artifacts pipeline:
build → sign → deploy. It wraps the lower-level reusable workflows and
provides a small, opinionated input surface.

## Design Philosophy

This orchestrator is the simpler of two supported approaches: it handles the full build, sign, deploy lifecycle behind a small input surface so consumers only provide a build script and configuration. It is opinionated and trades flexibility for ergonomics.

The other approach is the composable pipeline: call `reusable_execute-build.yaml`, `reusable_sign-artifacts.yaml`, and `reusable_deploy-artifacts.yaml` directly from your own job graph. That path is more flexible (custom steps between stages, per-stage overrides, non-standard layouts) at the cost of more wiring on your end. See [CICD-composable.md](https://github.com/aerospike/shared-workflows/blob/main/.github/workflows/docs/CICD-composable.md) for that workflow.

Pick whichever fits. If the orchestrator covers your use case, prefer it because there's less boilerplate to maintain. If you need finer-grained control, the composable path is a first-class option, not a fallback.

## Usage

```yaml
jobs:
  ci:
    uses: aerospike/shared-workflows/.github/workflows/reusable_artifacts-cicd.yaml@v2.0.3
    with:
      gh-workflows-ref: v2.0.3
      jf-project: my-project
      jf-build-name: my-app
      version: 1.2.3
      gh-artifact-directory: dist
      build-script: |
        make build
      # Optional:
      build-type: release # Freeform label, applied as build.type target-prop
      internal: false # Set true to mark artifacts as internal-only
      # Java/Maven (passed through to execute-build):
      setup-java: true
      java-version: "8"
      java-distribution: temurin
    secrets: inherit
```

## Supported artifact types

The deploy stage automatically routes artifacts by file extension:

| Type    | Repository suffix   | Properties                                                                         |
| ------- | ------------------- | ---------------------------------------------------------------------------------- |
| DEB     | `deb-dev-local`     | `version`, `package_name`, `deb.distribution`, `deb.component`, `deb.architecture` |
| RPM     | `rpm-dev-local`     | `version`, `package_name`, `rpm.distribution`, `rpm.component`, `rpm.architecture` |
| JAR     | `maven-dev-local`   | `version`, `group_id`, `package_name`                                              |
| NuGet   | `nuget-dev-local`   | `version`, `package_name`                                                          |
| npm     | `npm-dev-local`     | `version`, `package_name`                                                          |
| PyPI    | `pypi-dev-local`    | `version`, `package_name`, `pypi.name`, `pypi.version`                             |
| Go      | `go-dev-local`      | `version`, `package_name`, `go.module`, `go.version`                               |
| Helm    | `helm-dev-local`    | `version`, `package_name`, `helm.name`, `helm.version`                             |
| Generic | `generic-dev-local` | `version`, `package_name`                                                          |

Companion files (`.asc` signatures, `.pom` files, helm `.prov` provenance) are automatically gathered alongside their parent artifacts. Helm registers `.prov` (helm-native provenance signature) as its companion; the orphan `.tgz.asc` produced by GPG sign-artifacts is intentionally not gathered or uploaded for helm charts because `.prov` is the canonical chart signature.

### Helm charts

Helm charts publish to a JFrog classic Helm repository (`{project}-helm-dev-local`, a `artifactory_local_helm_repository` resource in tf-artifactory). JFrog auto-generates `index.yaml` from uploaded `.tgz` files, so consumers add the repo and install with the standard helm CLI:

```bash
helm repo add aerospike-helm \
  https://artifact.aerospike.io/artifactory/api/helm/{project}-helm-dev-local
helm repo update
helm install my-release aerospike-helm/<chart-name>
```

Packaging is the consumer's build-script responsibility, mirroring the npm/pypi/go convention. Run `helm package charts/<name> -d <output-dir>` and the deploy stage auto-detects the resulting `.tgz`.

Signing happens automatically in the sign stage. `sign-artifacts` recognises chart `.tgz` files and produces a helm-native `.prov` (GPG-clearsigned Chart.yaml plus a sha256 of the tarball) using the same GPG key it uses for deb/rpm/`.asc`. Build-scripts should run plain `helm package` (no `--sign`) and let the workflow handle provenance. The `.prov` rides alongside the chart through deploy and lands as a companion in the helm repo. Consumers verify with `helm install --verify` or `helm verify chart.tgz`.

Chart linting and unit testing are the user's responsibility. Suggestion is to run [chart-testing (`ct`)](https://github.com/helm/chart-testing) via the [helm/chart-testing-action](https://github.com/helm/chart-testing-action) as a separate `pull_request`-triggered workflow.

## Notes

- The workflow generates a parent build-id automatically.
- All artifacts get `version` and `package_name` target-props. Use `build-type` and `internal` for additional categorization.
- **Java/Maven:** Set `setup-java: true` and optionally `java-version` (e.g. `"8"`, `"17"`), `java-distribution` (default `temurin`), and `java-cache` (default `maven`). These are passed through to the build step so Java is set up before your `build-script` runs. Matrix entries can override them per build (e.g. `setup-java: true`, `java-version: "17"`).

## Testing

A single integration test workflow (`test_artifacts-cicd.yaml`) calls the orchestrator with a 4-entry matrix:

| Matrix entry | Runner        | Artifact type  |
| ------------ | ------------- | -------------- |
| el9 x86_64   | ubuntu-latest | RPM            |
| jammy x86_64 | ubuntu-latest | DEB            |
| dotnet any   | ubuntu-latest | NuGet (.nupkg) |
| darwin arm64 | macos-14      | .pkg           |

A verify job downloads `signed-artifacts` and runs `test_artifacts_cicd.bats` to validate presence, signatures, sizing, and naming.

### Running Tests

```bash
# Run bats tests locally (unit-level, no workflow execution)
bats .github/workflows/artifacts-cicd/tests/
```

Tests run automatically as PR checks.
