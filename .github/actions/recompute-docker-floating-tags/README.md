# Recompute Docker floating tags

Point `latest` and `latest-*` in one stage's Docker repository at the highest version tag still in that repository. Promotion runs this after `jf release-bundle-promote`. Run it again yourself when a release leaves a stage.

Floating tags belong to the repository, not to one release bundle. Promotion copies the version tags that are in the bundle. This action then retags `latest` from whatever version tags are in the target repository. A release that leaves the stage does not take `latest` with it unless something recomputes the tag. There is no un-promote workflow in this repo, and this action does not delete the bundle. `delete-release-bundle` still refuses a bundle that has been promoted beyond DEV.

## What it retags

The bundle property `docker.floating_tags` names the images and floating tags, for example `aerospike-graph-service:latest;aerospike-graph-service:latest-slim`.

For each image, in the repository you pass:

- The property lists only floating tags the build was asked to push. A version tag does not add `latest` or `latest-slim`.
- `latest` tracks the highest dotted version with no variant suffix (`3.3.2` > `3.3.1`, `8.2.0.0` > `8.1.0.0`).
- `latest-<suffix>` (for example `latest-slim`) tracks the highest version that ends in that suffix, compared after stripping it.
- Digest tags (`sha256:` / `sha256__`) and immutable tags (`_<YYYYMMDD>T<HHMMSS>Z`) are ignored.
- A suffixed tag never becomes `latest`.
- If the repository has no candidate version tag, the floating tag is removed.
- Promoting an older release while a newer version tag is already present leaves `latest` on the newer tag.

The floating tag is pointed at the same manifest as the chosen version tag. The target repository is the one you supply. This action does not rewrite `-dev-local` into another suffix.

## Prerequisites

JFrog CLI must be configured before calling this action (via `setup-jfrog-cli`).

## Inputs

| Input           | Required | Description                                                                                  |
| --------------- | -------- | -------------------------------------------------------------------------------------------- |
| `jf-project`    | Yes      | JFrog project key                                                                            |
| `docker-repo`   | Yes      | Stage Docker or OCI repository key to retag                                                  |
| `bundle-name`   | Yes      | Release bundle whose `docker.floating_tags` property names the images                        |
| `version`       | Yes      | Release bundle version                                                                       |
| `floating-tags` | No       | Optional `docker.floating_tags` value. When empty, the value is read from the release bundle |

## Command

The action runs `recompute.py retag`. The same file can be run directly when JFrog CLI is already configured. `print-property` prints the bundle property, `select` chooses a version from tags you pass, and `repos` reads a promotion result or repository catalog on stdin.

```bash
python3 .github/actions/recompute-docker-floating-tags/recompute.py retag \
  --project connect \
  --repo connect-docker-stage-local \
  --bundle-name aerospike-graph-service-container \
  --version 3.3.2
```

```bash
python3 -m unittest discover .github/actions/recompute-docker-floating-tags/tests
```

## Example

After a release leaves STAGE, recompute that stage so `latest` follows the newest version tag that is still there:

```yaml
- uses: aerospike/shared-workflows/.github/actions/recompute-docker-floating-tags@<sha> # vX.Y.Z
  with:
    jf-project: connect
    docker-repo: connect-docker-stage-local
    bundle-name: aerospike-graph-service-container
    version: 3.3.2
```
