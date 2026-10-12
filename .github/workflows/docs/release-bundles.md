# Release Bundles

At Aerospike, release bundles are the **only way artifacts are promoted between promotion stages**. Instead of promoting individual builds, we group all artifacts for a release into a [Release Bundle v2](https://jfrog.com/help/r/jfrog-artifactory-documentation/understanding-release-bundles-v2) and promote the bundle through DEV, TEST, STAGE, PREVIEW, and PROD.

## Why bundles

JFrog [Release Bundles v2](https://jfrog.com/help/r/jfrog-artifactory-documentation/understanding-release-bundles-v2) provide:

- **Immutability**: once created, a bundle's contents cannot change. This guarantees that what was tested is what gets promoted.
- **Promotion tracking**: each promotion-stage transition (DEV to TEST, TEST to STAGE, etc.) is recorded with who promoted and when, creating an auditable chain of custody.
- **Multi-artifact grouping**: a single bundle can reference multiple builds (e.g., artifact pipeline + Docker pipeline), so everything for a release moves together.

## Aerospike's promotion pipeline

Artifacts flow through gated promotion stages. Each gate has an owner and requirements that must be met before promotion.

```text
CI/Build  ->  [DEV]  ->  TEST  ->  STAGE  ->  [PREVIEW]  ->  PROD
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

DEV and PREVIEW, in brackets, are optional: a version can go from CI straight to TEST, and from STAGE straight to PROD. STAGE requires TEST, and PREVIEW, INTERNAL and PROD require STAGE.

The release bundle is created after the build deploys to the dev-local repositories. From then on, the bundle carries all artifacts and metadata through the remaining promotion stages.

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
```

Set `dry-run: true` to check the configuration and JFrog authentication: the workflow prints the JFrog commands instead of running them.

### Bundle revisions

Set `jf-bundle-revision` to give each build of a release its own bundle version. See [Bundle revisions](../create-release-bundle/README.md#bundle-revisions).

### Promoting a bundle

Use `reusable_promote-release-bundle.yaml`. It enforces the stage order above, and `gh-environment` lets a gate owner approve each promotion. See [Promote Release Bundle](../promote-release-bundle/README.md).

The [promote-release-bundle composite action](https://github.com/aerospike/shared-workflows/blob/main/.github/actions/promote-release-bundle/README.md) skips the order check. Both take `include-repos` and `exclude-repos` (semicolon-separated target repositories, e.g. `my-project-deb-test-local;my-project-rpm-test-local`) to limit which repositories are promoted. With neither set, all are.

### Deleting a bundle before re-deploy

The `delete-release-bundle` composite action deletes a bundle version if it exists and outputs `existed`. It refuses when the version is promoted, or being promoted, to any stage other than DEV; a failed promotion does not count. Run it before deploy when a re-run would redeploy paths that a bundle at DEV has locked. `version` is the bundle version: with a revision, pass that revision's bundle version, not the release version.

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

Set `gh-upload-bundle-metadata: false` on deploy when the metadata handoff is not needed.

## Troubleshooting

**Bundle creation fails**: confirm the `jf-build-names` input is a comma-separated list of `name:version` pairs that exist in JFrog, and that your project permissions allow bundle creation. Bundle creation requires higher permissions than artifact upload.

**Re-deploy fails with a permission error**: a promoted bundle locks its artifacts in the dev-local repos, so a re-run that uploads the same paths fails. If the bundle is promoted only to DEV, delete it first with `delete-release-bundle`, which is safe to run on every pipeline. If the bundle is promoted past DEV, the action refuses to delete it; deploy a new version instead.

## References

### JFrog documentation

- [Understanding Release Bundles v2](https://jfrog.com/help/r/jfrog-artifactory-documentation/understanding-release-bundles-v2)
- [Promote a Release Bundle v2](https://jfrog.com/help/r/jfrog-artifactory-documentation/promote-a-release-bundle-v2-to-a-target-environment)
- [Release Bundle v2 Repositories](https://jfrog.com/help/r/jfrog-artifactory-documentation/release-bundle-v2-repositories)
- [Release Lifecycle Management Setup](https://docs.jfrog.com/governance/docs/release-lifecycle-management-setup)

### Aerospike Confluence

- [SDLC pipeline with JFrog](https://aerospike.atlassian.net/wiki/spaces/DevOps/pages/4329996803/SDLC+pipeline+with+jfrog): foundational pipeline design
- [Pipeline with gates, QE, Cloud, Product](https://aerospike.atlassian.net/wiki/spaces/DevOps/pages/4577493063/Pipeline+with+gates+QE+Cloud+Product): gate definitions and evidence requirements
- [Artifact Repository Strategy for CI/CD with JFrog](https://aerospike.atlassian.net/wiki/spaces/AE/pages/4993155080/OPEN+Artifact+Repository+Strategy+for+CI+CD+with+JFrog): stable vs preview repository separation
