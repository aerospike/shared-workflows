# Release Bundles

At Aerospike, release bundles are the **only way artifacts are promoted between environments**. Instead of promoting individual builds, we group all artifacts for a release into a [Release Bundle v2](https://jfrog.com/help/r/jfrog-artifactory-documentation/understanding-release-bundles-v2) and promote the bundle through DEV, TEST, STAGE, PREVIEW, and PROD.

## Why bundles

JFrog [Release Bundles v2](https://jfrog.com/help/r/jfrog-artifactory-documentation/understanding-release-bundles-v2) provide:

- **Immutability**: once created, a bundle's contents cannot change. This guarantees that what was tested is what gets promoted.
- **Promotion tracking**: each environment transition (DEV to TEST, TEST to STAGE, etc.) is recorded with who promoted and when, creating an auditable chain of custody.
- **Multi-artifact grouping**: a single bundle can reference multiple builds (e.g., artifact pipeline + Docker pipeline), so everything for a release moves together.

These properties make bundles the right unit for our SDLC promotion model.

## Aerospike's promotion pipeline

Artifacts flow through gated environments. Each gate has an owner and requirements that must be met before promotion.

```text
CI/Build  ->  DEV  ->  TEST  ->  STAGE  ->  PREVIEW  ->  PROD
                                          ->  INTERNAL
```

| Environment | Owner       | Gate requirement                         |
| ----------- | ----------- | ---------------------------------------- |
| DEV         | Engineering | Build + smoke tests pass                 |
| TEST        | QE          | Basic integration tests pass             |
| STAGE       | QE          | Deep integration and performance testing |
| PREVIEW     | Product     | Customer preview validation              |
| PROD        | Product     | Security review and production readiness |
| INTERNAL    | Engineering | Internal-only artifacts (not public)     |

The release bundle is created after deployment to DEV (at the DEV to TEST gate). From that point forward, the bundle carries all artifacts and metadata through the remaining environments.

For the full gate definitions and evidence requirements, see:

- [Pipeline with gates, QE, Cloud, Product](https://aerospike.atlassian.net/wiki/spaces/DevOps/pages/4577493063/Pipeline+with+gates+QE+Cloud+Product)
- [SDLC pipeline with JFrog](https://aerospike.atlassian.net/wiki/spaces/DevOps/pages/4329996803/SDLC+pipeline+with+jfrog)

## Using bundles in shared-workflows

Use `reusable_create-release-bundle.yaml` to create a release bundle as a standalone job in your pipeline. It handles checkout and JFrog setup.

```yaml
release-bundle:
  needs: [deploy]
  uses: aerospike/shared-workflows/.github/workflows/reusable_create-release-bundle.yaml@v3.3.0
  with:
    gh-workflows-ref: v3.3.0
    jf-build-names: "my-app:1.2.3,my-container:1.2.3"
    jf-bundle-name: my-release
    version: 1.2.3
    jf-project: my-project
  secrets: inherit
```

There is a composite action that may be used for promotion of bundles documented at [Promote Release Bundle Composite Action](https://github.com/aerospike/shared-workflows/blob/main/.github/actions/promote-release-bundle/README.md).

For a complete working example including bundle deletion and promotion, see [example_composable-matrix.yaml](https://github.com/aerospike/shared-workflows/blob/main/.github/workflows/example_composable-matrix.yaml).

## Troubleshooting

**Bundle creation fails**: confirm the `jf-build-names` input is a comma-separated list of `name:version` pairs that exist in JFrog, and that your project permissions allow bundle creation. Bundle creation requires higher permissions than artifact upload.

**Promoted bundle locks artifacts**: promoted bundles lock the underlying artifacts in dev-local repos, causing re-deploy uploads to fail with permission errors. Either delete the old bundle before deploying, or increment the version/build ID.

**Re-running a pipeline**: if the bundle already exists and has been promoted, you must delete it before deploying new artifacts with the same names/path.

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
