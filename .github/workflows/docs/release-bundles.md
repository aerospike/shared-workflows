# Release Bundles

At Aerospike, release bundles are the **only way artifacts are promoted between promotion stages**. Instead of promoting individual builds, we group all artifacts for a release into a [Release Bundle v2](https://jfrog.com/help/r/jfrog-artifactory-documentation/understanding-release-bundles-v2) and promote the bundle through DEV, TEST, STAGE, PREVIEW, and PROD.

## Why bundles

JFrog [Release Bundles v2](https://jfrog.com/help/r/jfrog-artifactory-documentation/understanding-release-bundles-v2) provide:

- **Immutability**: once created, a bundle's contents cannot change. This guarantees that what was tested is what gets promoted.
- **Promotion tracking**: each promotion-stage transition (DEV to TEST, TEST to STAGE, etc.) is recorded with who promoted and when, creating an auditable chain of custody.
- **Multi-artifact grouping**: a single bundle can reference multiple builds (e.g., artifact pipeline + Docker pipeline), so everything for a release moves together.

These properties make bundles the right unit for our SDLC promotion model.

## Aerospike's promotion pipeline

Artifacts flow through gated promotion stages. Each gate has an owner and requirements that must be met before promotion.

```text
CI/Build  ->  DEV  ->  TEST  ->  STAGE  ->  PREVIEW  ->  PROD
                                          ->  INTERNAL
```

| Promotion stage | Owner       | Gate requirement                         |
| --------------- | ----------- | ---------------------------------------- |
| DEV             | Engineering | Build + smoke tests pass                 |
| TEST            | QE          | Basic integration tests pass             |
| STAGE           | QE          | Deep integration and performance testing |
| PREVIEW         | Product     | Customer preview validation              |
| PROD            | Product     | Security review and production readiness |
| INTERNAL        | Engineering | Internal-only artifacts (not public)     |

The release bundle is created after deployment to DEV (at the DEV to TEST gate). From that point forward, the bundle carries all artifacts and metadata through the remaining promotion stages.

For the full gate definitions and evidence requirements, see:

- [Pipeline with gates, QE, Cloud, Product](https://aerospike.atlassian.net/wiki/spaces/DevOps/pages/4577493063/Pipeline+with+gates+QE+Cloud+Product)
- [SDLC pipeline with JFrog](https://aerospike.atlassian.net/wiki/spaces/DevOps/pages/4329996803/SDLC+pipeline+with+jfrog)

## Using bundles in shared-workflows

Use `reusable_create-release-bundle.yaml` to create a release bundle as a standalone job in your pipeline. It handles checkout and JFrog setup.

```yaml
release-bundle:
  needs: [deploy]
  uses: aerospike/shared-workflows/.github/workflows/reusable_create-release-bundle.yaml@v3.2.0
  with:
    gh-workflows-ref: v3.2.0
    jf-build-names: "my-app:1.2.3,my-container:1.2.3"
    jf-bundle-name: my-release
    version: 1.2.3
    jf-project: my-project
  secrets: inherit
```

Set `dry-run: true` to validate the configuration and JFrog authentication without actually creating the bundle. In dry-run mode the workflow echoes the commands it would run instead of calling `jf release-bundle-create`.

There is a composite action that may be used for promotion of bundles documented at [Promote Release Bundle Composite Action](https://github.com/aerospike/shared-workflows/blob/main/.github/actions/promote-release-bundle/README.md). The `promote-release-bundle` action accepts `include-repos` and `exclude-repos` (semicolon-separated repo lists, e.g. `my-project-deb-dev-local;my-project-rpm-dev-local`) to scope which repositories are promoted. With neither set, all repositories in the bundle are promoted.

### Deleting a bundle before re-deploy

The `delete-release-bundle` composite action deletes a bundle version safely: it searches first, no-ops when the bundle is absent, and reports `existed=true/false` rather than failing. **Promotion guards** run twice when a bundle exists: before delete is attempted and again immediately before `jf release-bundle-delete-local`, refusing deletion when the version is promoted beyond DEV (TEST, STAGE, PREVIEW, INTERNAL, PROD). Wire it to run before deploy when you may re-run a pipeline against an already-promoted bundle (promoted bundles lock the underlying dev-local artifacts).

```yaml
delete-existing-bundle:
  uses: aerospike/shared-workflows/.github/actions/delete-release-bundle@v3.2.0
  with:
    bundle-name: my-release
    version: 1.2.3
    jf-project: my-project
```

For a complete working example including bundle deletion and promotion, see [example_composable-matrix.yaml](https://github.com/aerospike/shared-workflows/blob/main/.github/workflows/example_composable-matrix.yaml).

### Maven bundle metadata (multi-module / flattened layouts)

After deploy, `reusable_deploy-artifacts.yaml` can upload `structured_build_artifacts/.maven-bundle-metadata.json` as a separate GitHub artifact (see outputs `bundle-metadata-artifact-name` / `bundle-metadata-available`). Pass that name to `reusable_create-release-bundle.yaml` as `gh-bundle-metadata-artifact-name` so the bundle job downloads the JSON and runs `jf release-bundle-annotate` without checking out the consumer repository. Alternatively, set `bundle-metadata-path` when the JSON is already on disk in that job.

The metadata upload requires `actions: write` on your **top-level** caller workflow (or job). Grant it alongside `contents: read` and `id-token: write`, or set `gh-upload-bundle-metadata: false` on deploy when metadata handoff is not needed.

## Troubleshooting

**Bundle creation fails**: confirm the `jf-build-names` input is a comma-separated list of `name:version` pairs that exist in JFrog, and that your project permissions allow bundle creation. Bundle creation requires higher permissions than artifact upload.

**Promoted bundle locks artifacts**: promoted bundles lock the underlying artifacts in dev-local repos, causing re-deploy uploads to fail with permission errors. Either delete the old bundle before deploying (use the `delete-release-bundle` action), or increment the version/build ID.

**Re-running a pipeline**: if the bundle already exists and has been promoted, delete it before deploying new artifacts with the same names/path. The `delete-release-bundle` action is safe to call unconditionally (it no-ops when the bundle is absent), so it can run on every pipeline before deploy.

## References

### JFrog documentation

- [Understanding Release Bundles v2](https://jfrog.com/help/r/jfrog-artifactory-documentation/understanding-release-bundles-v2)
- [Promote a Release Bundle v2](https://jfrog.com/help/r/jfrog-artifactory-documentation/promote-a-release-bundle-v2-to-a-target-environment)
- [Release Bundle v2 Repositories](https://jfrog.com/help/r/jfrog-artifactory-documentation/release-bundle-v2-repositories)
- [Release Lifecycle Management Setup](https://docs.jfrog.com/governance/docs/release-lifecycle-management-setup)

### Aerospike Confluence

- [SDLC pipeline with JFrog](https://aerospike.atlassian.net/wiki/spaces/DevOps/pages/4329996803/SDLC+pipeline+with+jfrog) -- foundational pipeline design
- [Pipeline with gates, QE, Cloud, Product](https://aerospike.atlassian.net/wiki/spaces/DevOps/pages/4577493063/Pipeline+with+gates+QE+Cloud+Product) -- gate definitions and evidence requirements
- [Artifact Repository Strategy for CI/CD with JFrog](https://aerospike.atlassian.net/wiki/spaces/AE/pages/4993155080/OPEN+Artifact+Repository+Strategy+for+CI+CD+with+JFrog) -- stable vs preview repository separation
