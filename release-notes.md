<!-- markdownlint-disable MD024 -->

# Release notes (since v3.8.0)

Breaking changes for consumer repositories. A breaking change is any update that may require edits to a caller workflow, permissions, secrets, or pipeline behavior when upgrading from **v3.8.0**.

Versions are listed newest first. Workflows and jobs are listed alphabetically within each version.

---

## Quick upgrade reference

| Caller setup                                                     | Upgrade to        | Required caller change                                                        |
| ---------------------------------------------------------------- | ----------------- | ----------------------------------------------------------------------------- |
| Rust `.crate` in build output                                    | unreleased `main` | Verify new routing and properties; invalid crates no longer upload as generic |
| Composable deploy → create-release-bundle with metadata artifact | ≥ v3.9.1          | Add `actions: write` and `actions: read`                                      |
| Same pipeline with release-bundle metadata handoff               | ≥ v3.9.1          | Add `actions: write` and `actions: read`                                      |
| Re-run pipeline deleting same bundle version after promotion     | ≥ v3.9.0          | Stop deleting promoted bundles, or bump version                               |
| Composable deploy, Maven metadata disabled                       | ≥ v3.8.2          | None (`gh-upload-bundle-metadata: false`)                                     |
| Composable deploy with Maven metadata                            | ≥ v3.8.2          | Add `actions: write`                                                          |
| Orchestrated `reusable_artifacts-cicd.yaml` with Maven/JAR       | ≥ v3.8.2          | Add `actions: write`                                                          |
| Dependabot-triggered signing                                     | ≥ v3.8.1          | Expect unsigned GPG artifacts unless Dependabot is excluded                   |

---

## unreleased (`main`, post-v3.9.1)

### `reusable_artifacts-cicd.yaml`

#### `deploy-signed`

- Calls `reusable_deploy-artifacts.yaml` with default `gh-upload-bundle-metadata: true`. Inherits Rust `.crate` deploy behavior below; no new orchestrator inputs were added.

### `reusable_deploy-artifacts.yaml`

#### `deploy`

- **Rust `.crate` support (INFRA-608):** valid Cargo `.crate` archives are structured under `crate/` and uploaded to `{project}-generic-dev-local` with `cargo.name` and `cargo.version` target properties.
- Invalid `.crate` files (missing or invalid `Cargo.toml` inside the archive) are skipped instead of falling through to generic upload.
- **Action needed if:** you already publish `.crate` files and relied on generic routing or properties; or you have non-Cargo files named `*.crate` that previously uploaded as generic artifacts.

---

## v3.9.1

### `reusable_artifacts-cicd.yaml`

#### `deploy-signed`

- **Action needed if:** your pipeline chains deploy metadata into `reusable_create-release-bundle.yaml` via `gh-bundle-metadata-artifact-name`. The top-level caller must grant `actions: read` (in addition to `actions: write` for metadata upload). The orchestrator does not expose inputs to disable metadata upload or pass bundle metadata to create-release-bundle; composable wiring or caller permission updates are required.

### `reusable_create-release-bundle.yaml`

#### `create-release-bundle`

- **`actions: read` moved from workflow scope to job scope.** Workflow scope is now only `contents: read` and `id-token: write`.
- **Action needed if:** `gh-bundle-metadata-artifact-name` is set (download `.maven-bundle-metadata.json` from a prior deploy job). Add `actions: read` to the top-level caller workflow or job permissions.
- **Alternative:** omit `gh-bundle-metadata-artifact-name` and use `bundle-metadata-path` on disk, or skip metadata annotation.

---

## v3.9.0

### `reusable_artifacts-cicd.yaml`

#### `deploy-signed`

- Inherits Maven deploy structuring changes from `reusable_deploy-artifacts.yaml` (see below).
- Calls deploy with default `gh-upload-bundle-metadata: true` and does not expose an input to disable it.
- **Action needed if:** you build Maven/JAR artifacts — add `actions: write` to the top-level caller permissions so metadata upload can succeed.

### `reusable_create-release-bundle.yaml`

#### `create-release-bundle`

- **Related composite action `delete-release-bundle` (often called before bundle recreate):** refuses deletion when the bundle version has completed promotions beyond DEV (TEST, STAGE, PREVIEW, INTERNAL, PROD).
- **Action needed if:** your pipeline deletes and recreates a bundle at the same version after promotion — bump the bundle version or stop deleting promoted bundles.

### `reusable_deploy-artifacts.yaml`

#### `deploy`

- **Maven structuring behavior changed (INFRA-612):**
  - Standalone and jar-less POMs (BOMs, parent aggregators) structure under `jar/{groupId}/{artifactId}/{version}/` with sidecars (`.pom.asc`, `.md5`, `.sha1`).
  - POMs in JFrog nested download layout (`.../group/artifact/version/`) are detected and structured correctly.
  - `.jar` and `.pom` files no longer leak into the generic bucket when Maven detection applies.
- **Action needed if:**
  - You depended on Maven artifacts landing in `{project}-generic-dev-local` instead of `{project}-maven-dev-local`.
  - You chain release bundles via `gh-bundle-metadata-artifact-name` and rely on `.maven-bundle-metadata.json` shape or module counts — metadata may differ (more accurate reactor detection).
  - Artifacts use nested repo layout but were previously skipped during detection.

---

## v3.8.2

### `reusable_artifacts-cicd.yaml`

#### `deploy-signed`

- Calls `reusable_deploy-artifacts.yaml`, which now scopes `actions: write` to the deploy job only.
- **Action needed if:** you build Maven/JAR artifacts and rely on `.maven-bundle-metadata.json` upload (deploy default `gh-upload-bundle-metadata: true`). Add `actions: write` to the top-level caller workflow permissions.
- JFrog deploy still succeeds without `actions: write`; only the optional metadata GitHub artifact upload step fails.

### `reusable_deploy-artifacts.yaml`

#### `deploy`

- **`actions: write` moved from workflow scope to job scope.** Workflow scope is now only `contents: read` and `id-token: write`.
- Fixes workflow validation / `startup_failure` when composable callers grant only `contents: read` and `id-token: write`.
- **Action needed if:** `gh-upload-bundle-metadata` is `true` (default) and Maven metadata is produced. Add `actions: write` to the top-level caller workflow or job permissions.
- **Alternative:** set `gh-upload-bundle-metadata: false` on the deploy call when metadata handoff is not needed.

---

## v3.8.1

### `reusable_artifacts-cicd.yaml`

#### `sign`

- Delegates to `reusable_sign-artifacts.yaml` and inherits GPG signing eligibility changes (see below).

### `reusable_sign-artifacts.yaml`

#### `sign`

- **GPG signing is skipped** when the actor is `dependabot[bot]` or when `gpg-private-key` is unavailable.
- When GPG signing is skipped, unsigned artifacts are copied into the signed artifact tree so downstream jobs still receive build outputs.
- **Action needed if:** you run signing on Dependabot pushes and expect GPG signatures — accept unsigned artifacts downstream, or exclude Dependabot from signing jobs.
