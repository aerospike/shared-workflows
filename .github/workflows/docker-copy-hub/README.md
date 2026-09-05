# Reusable Docker Copy to Docker Hub

Copies **already published** OCI tags from JFrog Artifactory to Docker Hub.

This is not `reusable_docker-build-deploy.yaml`. It does **not** build images,
does **not** retag into another Artifactory repository, and does **not** push
anything back to JFrog. It reuses the same JFrog OIDC login and
`docker buildx imagetools create` registry-to-registry copy that
`docker-build-deploy` uses when assembling a manifest.

## What the aerospike-tools run does

Pull these existing tags from JFrog and place the same tag names on Docker Hub:

| Source | Destination |
| --- | --- |
| `artifact.aerospike.io/docker/aerospike-tools:13.0.3-5` | `aerospike/aerospike-tools:13.0.3-5` |
| `artifact.aerospike.io/docker/aerospike-tools:13.0.3-5-amd64` | `aerospike/aerospike-tools:13.0.3-5-amd64` |
| `artifact.aerospike.io/docker/aerospike-tools:13.0.3-5-arm64` | `aerospike/aerospike-tools:13.0.3-5-arm64` |

Public tags: [aerospike/aerospike-tools](https://hub.docker.com/r/aerospike/aerospike-tools/tags)

## Secrets

The workflow must run in a repository in the `aerospike` GitHub org. Org
secrets are not available on a personal fork.

| Workflow secret | Org secret | Used for |
| --- | --- | --- |
| `dockerhub-username` | `DOCKERHUB_USERNAME` | Docker Hub login |
| `dockerhub-token` | `DOCKERHUB_TOKEN` | Docker Hub login |

JFrog authentication is OIDC (`id-token: write`), not a static secret. The
token is used only to **pull** from `artifact.aerospike.io`.

If the org secret names differ, remap them in the caller:

```yaml
secrets:
  dockerhub-username: ${{ secrets.DOCKERHUB_USERNAME }}
  dockerhub-token: ${{ secrets.DOCKERHUB_TOKEN }}
```

## How to execute

The copy must run on `aerospike/shared-workflows` (or another aerospike-org
repo that can read those org secrets). A fork can hold the PR, but it cannot
publish to Docker Hub with org credentials.

### 1. Dry run (inspect JFrog only)

1. Open [Actions → Example Docker Copy to Docker Hub](https://github.com/aerospike/shared-workflows/actions/workflows/example_docker-copy-hub.yaml)
   on the `aerospike/shared-workflows` repo, on a branch that contains this
   workflow.
2. **Run workflow**
3. Leave the defaults:
   - source: `artifact.aerospike.io/docker/aerospike-tools`
   - dest: `aerospike/aerospike-tools`
   - tags: `13.0.3-5,13.0.3-5-amd64,13.0.3-5-arm64`
   - **dry-run: checked (true)**
4. Confirm the run summary lists a digest for each of the three source tags.

Or with the GitHub CLI from a machine that can trigger workflows on the org repo:

```shell
gh workflow run example_docker-copy-hub.yaml \
  --repo aerospike/shared-workflows \
  --ref feat/docker-copy-hub \
  -f dry-run=true \
  -f source-image=artifact.aerospike.io/docker/aerospike-tools \
  -f dest-image=aerospike/aerospike-tools \
  -f tags=13.0.3-5,13.0.3-5-amd64,13.0.3-5-arm64
```

### 2. Copy to Docker Hub

Same workflow, uncheck **dry-run** (or pass `dry-run=false`):

```shell
gh workflow run example_docker-copy-hub.yaml \
  --repo aerospike/shared-workflows \
  --ref feat/docker-copy-hub \
  -f dry-run=false \
  -f source-image=artifact.aerospike.io/docker/aerospike-tools \
  -f dest-image=aerospike/aerospike-tools \
  -f tags=13.0.3-5,13.0.3-5-amd64,13.0.3-5-arm64
```

The job fails if a destination digest does not match the source digest.

### 3. Confirm Hub

https://hub.docker.com/r/aerospike/aerospike-tools/tags should show
`13.0.3-5`, `13.0.3-5-amd64`, and `13.0.3-5-arm64`.

## Caller usage

```yaml
jobs:
  copy-to-dockerhub:
    uses: aerospike/shared-workflows/.github/workflows/reusable_docker-copy-hub.yaml@<sha>
    with:
      source-image: artifact.aerospike.io/docker/aerospike-tools
      dest-image: aerospike/aerospike-tools
      tags: 13.0.3-5,13.0.3-5-amd64,13.0.3-5-arm64
    secrets:
      dockerhub-username: ${{ secrets.DOCKERHUB_USERNAME }}
      dockerhub-token: ${{ secrets.DOCKERHUB_TOKEN }}
```

## Inputs

### Required

- `dest-image` (string): Destination image without tag (e.g. `aerospike/aerospike-tools`)
- `source-image` (string): Source image without tag (e.g. `artifact.aerospike.io/docker/aerospike-tools`)
- `tags` (string): Comma-separated tags to copy unchanged

### Optional / defaults

- `dry-run` (boolean, default `false`): Inspect source tags and skip the Docker Hub push
- `jf-project` (string, default `database`): JFrog project key used only to mint a read OIDC token
- `jf-url` (string, default `https://artifact.aerospike.io`)
- `oidc-audience` (string, default `aerospike`)
- `oidc-provider-name` (string, default `gh-aerospike`)
- `runs-on` (string, default `ubuntu-24.04`)

## Outputs

- `copied-tags`: Comma-separated `dest:tag@digest` values that were pushed (empty on dry-run)
- `source-digests`: Comma-separated `tag@digest` values read from JFrog
