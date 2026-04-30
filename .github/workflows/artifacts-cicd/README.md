# Artifacts CI/CD (Reusable Workflow)

This workflow orchestrates the standard artifacts pipeline:
build → sign → deploy. It wraps the lower-level reusable workflows and
provides a small, opinionated input surface.

## Design Philosophy

This orchestrator is the expected entry point for all artifact CI/CD. It handles the full build → sign → deploy lifecycle with good defaults and minimal configuration.

The lower-level workflows it wraps (`reusable_execute-build.yaml`, `reusable_sign-artifacts.yaml`, `reusable_deploy-artifacts.yaml`) are internal implementation details. If a consumer needs to call them directly, that's a smell — either this orchestrator is missing a needed capability, or the consumer's build process should be restructured to fit the standard path. Prefer extending the orchestrator over bypassing it.

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

Packaging is the consumer's build-script responsibility, mirroring the npm/pypi/go convention. Run `helm package charts/<name> -d <output-dir>` and the deploy stage auto-detects the resulting `.tgz` (sniffed via `<chart>/Chart.yaml` containing `apiVersion`, `name`, and `version`).

Signing happens automatically in the sign stage. `sign-artifacts` recognises chart `.tgz` files and produces a helm-native `.prov` (GPG-clearsigned Chart.yaml plus a sha256 of the tarball) using the same GPG key it uses for deb/rpm/`.asc`. Build-scripts should run plain `helm package` (no `--sign`) and let the workflow handle provenance. The `.prov` rides alongside the chart through deploy and lands as a companion in the helm repo. Consumers verify with `helm install --verify` or `helm verify chart.tgz`.

Chart linting and unit testing are out of scope for this orchestrator (publishing is a release-time concern, linting is a PR-time concern). Run [chart-testing (`ct`)](https://github.com/helm/chart-testing) via the [helm/chart-testing-action](https://github.com/helm/chart-testing-action) as a separate `pull_request`-triggered workflow. The [aerospike/helm-aerospike-vector-search](https://github.com/aerospike/helm-aerospike-vector-search) repo has a working `lint.yaml` + `.ct.yaml` you can copy verbatim.

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
