# Shared Workflows – CI/CD Walkthrough

This guide explains how Aerospike's cicd workflow is a central part of an end‑to‑end CI/CD pipeline.

---

## High‑level flow

The architecture follows an ecosystem-specific build & sign pattern, where artifacts are built and secured according to their type (DEB/RPM with GPG, Docker with attestations), then unified at the release bundle step.

### Artifact Pipeline (DEB, RPM, Generic files)

1. **Artifacts CICD** → compile/build, sign, deploy your project and produce artifacts

### Docker Pipeline (Container images)

1. **Docker Build & Deploy** → build, attest (SLSA provenance), and publish OCI images

### Unified Release

**Create Release Bundle** → combine artifacts and/or docker builds into a single distributable release bundle

## Standard Workflows for your project

These orchestrated workflows are the expected entry points for all repositories:

- `reusable_artifacts-cicd.yaml`: **Artifacts pipeline** (build → sign → deploy). [README](https://github.com/aerospike/shared-workflows/blob/main/.github/workflows/artifacts-cicd/README.md)
- `reusable_docker-build-deploy.yaml`: **Docker pipeline** (container images with SLSA attestations). [README](https://github.com/aerospike/shared-workflows/blob/main/.github/workflows/docker-build-deploy/README.md)
- `reusable_create-release-bundle.yaml`: **Release bundles** (combines artifact + docker outputs). [README](https://github.com/aerospike/shared-workflows/blob/main/.github/workflows/create-release-bundle/README.md)

The lower-level workflows (`reusable_execute-build.yaml`, `reusable_sign-artifacts.yaml`, `reusable_deploy-artifacts.yaml`) are internal implementation details. If you find yourself calling them directly, that's usually a sign the orchestrator needs a new capability or the build process should be restructured to fit the standard path.

### Artifacts CI/CD

This orchestrates the full build → sign → deploy lifecycle internally.

```yaml
jobs:
  ci:
    uses: aerospike/shared-workflows/.github/workflows/reusable_artifacts-cicd.yaml@v2.0.3
    with:
      gh-workflows-ref: v2.0.3 # Must match @v2.0.3 above
      jf-project: my-project
      jf-build-name: my-app
      version: 1.2.3
      gh-artifact-directory: dist
      build-script: |
        make build

      # Optional:
      build-type: release # Freeform label, applied as build.type target-prop on all artifacts
      internal: false # Set true to mark artifacts as internal-only (promotion control)
    secrets: inherit
```

Notes:

- `reusable_artifacts-cicd.yaml` generates a unique parent `jf-build-id` internally (millisecond timestamp) and uses a distinct metadata build-id for the build-info produced during the build.
- Signing is always enabled; provide the required signing secrets (GPG, and SSL.com secrets if `.nupkg` files are present). Using `secrets: inherit` is simplest.
- All artifacts get `version` and `package_name` target-props automatically. DEB/RPM also get distribution and architecture. Use `build-type` and `internal` for additional categorization.

### Simple matrix builds (optional)

Use `matrix-json` to run a constrained matrix while keeping the rest of the workflow simple. Each matrix job publishes its own build-info and artifacts, then the workflow aggregates build-info and merges artifacts before signing/deploying.

`matrix-json` must conform to `https://github.com/aerospike/shared-workflows/blob/main/.github/workflows/docs/artifacts-cicd-matrix.schema.json`.

Use matrix fields for values the workflow already expects (`runs-on`, `distro`, `arch`). Use `build-env` only for extra variables your script needs. Use `\;` for literal semicolons.

Matrix entries can override these per-build settings:

- `working-directory`
- `gh-artifact-directory`
- `build-script`
- `build-script-path`
- `build-env`
- `setup-dotnet`
- `dotnet-version`

Precedence is always: **matrix entry override → workflow input defaults**.

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
      matrix-json: >-
        {"include":[
          {"runs-on":"ubuntu-22.04","distro":"jammy","arch":"x86_64"},
          {"runs-on":"ubuntu-22.04","distro":"noble","arch":"x86_64"}
        ]}
    secrets: inherit
```

#### Dotnet matrix entry example

```yaml
matrix-json: >-
  {"include":[
    {
      "runs-on":"ubuntu-22.04",
      "working-directory":"src/dotnet",
      "gh-artifact-directory":"src/dotnet/artifacts",
      "build-script":"./scripts/build-dotnet.sh",
      "build-env":"DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1",
      "setup-dotnet":true,
      "dotnet-version":"8.0.x"
    }
  ]}
```

## Example Usage

The typical pattern combines both pipelines: Build and sign according to ecosystem, then unify in a release bundle.

For a drop-in artifacts-cicd example see [example_artifacts-cicd.yaml](https://github.com/aerospike/shared-workflows/blob/main/.github/workflows/example_artifacts-cicd.yaml).

---

## Why gh-workflows-ref is required

All shared workflows require the `gh-workflows-ref` input, which **should match** the version in your `uses:` line:

```yaml
jobs:
  build:
    uses: aerospike/shared-workflows/.github/workflows/reusable_execute-build.yaml@v2.0.3
    with:
      gh-workflows-ref: v2.0.3 # Should match @v2.0.3 above
      # ... other inputs ...
```

### The problem

GitHub Actions has a fundamental limitation: **reusable workflows cannot access their own ref**. When you call `uses: org/repo/.github/workflows/workflow.yaml@v2.0.3`, the workflow itself has no way to know it was called with `@v2.0.3`.

The available context variables don't help:

- `github.sha` → SHA of the _caller's_ commit, not shared-workflows
- `github.workflow_sha` → SHA of the _caller's_ workflow file, not the reusable one
- `github.ref` → ref of the _caller's_ repository

There is no `github.called_workflow_ref` or similar.

### Why this matters

These workflows need to checkout their own repository to access entrypoint scripts (bash scripts that do the actual work). Without knowing which version was called, they can't checkout the matching scripts—leading to version mismatches where the workflow is v2.0.3 but the scripts are from a different version.

### Known issue

This is a long-standing GitHub Actions limitation with no native solution:

- [actions/runner#2417](https://github.com/actions/runner/issues/2417)
- [community/discussions#38659](https://github.com/orgs/community/discussions/38659)

Third-party workarounds exist but don't pass security review. Until GitHub adds native support, `gh-workflows-ref` is the reliable solution.

---

## Troubleshooting tips

- **Deploy fails (auth)** → confirm GitHub→JFrog **OIDC** trust/policy is configured and that the workflow's identity has deploy permission to the target project/repo. (example mistakes often around wrong audience or incorrect token permissions)
- **Docker push fails** → ensure `tag` includes the full registry path (e.g., `artifact.aerospike.io/project-docker-dev-local/image:tag`). Verify JFrog registry permissions and OIDC authentication.
- **Bundle creation issues** → confirm the `jf-build-names` input is a comma‑separated list of `name:build_id` pairs that exist for the specified `version`, and that your JFrog project/repo permissions allow bundle creation. This permission is higher than upload/download so often a source of error.

---
