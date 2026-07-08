# Artifacts CI/CD (Reusable Workflow)

This workflow orchestrates the standard artifacts pipeline:
build → sign → deploy. It wraps the lower-level reusable workflows and
provides a small, opinionated input surface.

## Design Philosophy

This orchestrator is the simpler of two supported approaches: it handles the full build, sign, deploy lifecycle behind a small input surface so consumers only provide a build script and configuration. It is opinionated and trades flexibility for ergonomics.

The other approach is the composable pipeline See [CICD-composable.md](https://github.com/aerospike/shared-workflows/blob/main/.github/workflows/docs/CICD-composable.md) for that workflow. (Hint if you want to integrate tests or custom steps between stages, the composable pipeline is the right choice rather than this one.)

## Workflow permissions

Grant at least `contents: read` and `id-token: write` on your caller workflow (or calling job):

```yaml
permissions:
  contents: read
  id-token: write
```

If your build produces Maven/JAR artifacts and you rely on bundle metadata for release bundles, also add `actions: write` so the deploy stage can upload `.maven-bundle-metadata.json` as a GitHub artifact. See [deploy-artifacts README](../deploy-artifacts/README.md#permissions).

## Usage

```yaml
jobs:
  ci:
    uses: aerospike/shared-workflows/.github/workflows/reusable_artifacts-cicd.yaml@v3.2.0
    with:
      gh-workflows-ref: v3.2.0
      jf-project: my-project
      jf-build-name: my-app
      version: 1.2.3
      gh-artifact-directory: dist
      oidc-audience: aerospike # Required
      oidc-provider-name: gh-aerospike # Required
      build-script: | # Provide build-script OR build-script-path, not both
        make build
      # Optional:
      build-type: release # Freeform label, applied as build.type target-prop
      internal: false # Set true to mark artifacts as internal-only
      # Java/Maven (passed through to execute-build):
      setup-java: true
      java-version: "21"
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
| Windows | `generic-dev-local` | `version`, `package_name`                                                          |
| Generic | `generic-dev-local` | `version`, `package_name`                                                          |

Windows executables (`.exe`, `.msi`, `.msix`) are detected by extension and routed to the generic repository; enable Authenticode signing for them with `sign-windows`. macOS `.pkg` installers produced by `sign-mac` are likewise uploaded as generic artifacts.

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

- When **`sign-windows: true`**, pass **`es_ov_username`**, **`es_ov_password`**, **`es_ov_credential_id`**, and **`es_ov_totp_secret`** into this workflow (for example from repository secrets **`ES_OV_USERNAME`**, **`ES_OV_PASSWORD`**, **`ES_OV_CREDENTIAL_ID`**, **`ES_OV_TOTP_SECRET`**). NuGet signing in the same pipeline still uses **`es-username`**, **`es-password`**, **`credential_id`**, and **`es-totp_secret`**.
- The workflow generates a parent build-id automatically.
- All artifacts get `version` and `package_name` target-props. Use `build-type` and `internal` for additional categorization.
- **OIDC:** `oidc-audience` and `oidc-provider-name` are required. Aerospike consumers normally use `oidc-audience: aerospike` and `oidc-provider-name: gh-aerospike`.
- **Build script:** Provide either `build-script` (inline) or `build-script-path` (path to a script file), not both.
- **build-env:** Optional semicolon-delimited `KEY=VALUE` pairs exported into the build script's environment (use `\;` for a literal semicolon). Matrix-level `build-env` merges with the top-level value rather than replacing it.
- **Language/tool setup:** Set `setup-java: true` and optionally `java-version` (default `"21"`), `java-distribution` (default `temurin`), and `java-cache` (default `maven`). The same passthrough exists for `setup-dotnet` (`dotnet-version`, default `8.0`), `setup-python` (`python-version`, default `3.12`), and `setup-helm` (`helm-version`, default `latest`). Each toolchain is set up before your `build-script` runs. Matrix entries can override these per build.

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
