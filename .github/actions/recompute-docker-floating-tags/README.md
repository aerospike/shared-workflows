# Recompute Docker floating tags

Point a tag the caller named at the Docker tag supplied in `tag`, for example `3.3.2`. With only the repository, nothing is attached. Applying `latest` and `latest-slim` is optional, and both are off by default. Each flag writes that exact name for the image in `image`. Promotion calls this action only when its matching input is true.

Floating tags belong to the repository, not to one release bundle. Promotion copies the version tags that are in the bundle. There is no un-promote workflow in this repo, and this action does not delete the bundle. `delete-release-bundle` still refuses a bundle that has been promoted beyond DEV.

## What it retags

`floating-tags` is a semicolon-separated list of `image:tag` values the caller typed, for example `aerospike-graph-service:dev`.

`latest` and `latest-slim` are separate inputs. Both default to off. Set `latest: true` to apply `latest`, and `latest-slim: true` to apply `latest-slim`. Those two names require `image`.

The named tag is pointed at `tag`. This action does not rewrite `-dev-local` into another suffix.

## Prerequisites

JFrog CLI must be configured before calling this action (via `setup-jfrog-cli`).

## Inputs

| Input           | Required | Description                                                                                            |
| --------------- | -------- | ------------------------------------------------------------------------------------------------------ |
| `docker-repo`   | Yes      | Stage Docker or OCI repository key to retag                                                            |
| `tag`           | No       | Mutable Docker tag to point at, for example `3.3.2`. Required when a tag is applied                    |
| `image`         | No       | Image name for `latest` and `latest-slim`. Required when either of those inputs is true                |
| `floating-tags` | No       | `image:tag` list the caller typed, separated by semicolons (for example `aerospike-graph-service:dev`) |
| `latest`        | No       | Apply the `latest` tag. Optional, off by default                                                       |
| `latest-slim`   | No       | Apply the `latest-slim` tag. Optional, off by default                                                  |

## Command

The action runs `recompute.py retag`. The same file can be run directly when JFrog CLI is already configured.

```bash
python3 .github/actions/recompute-docker-floating-tags/recompute.py retag \
  --repo connect-docker-stage-local \
  --tag 3.3.2 \
  --floating-tags aerospike-graph-service:dev
```

`--latest` and `--latest-slim` are optional and off unless you pass them. Pass `--image` with either flag.

```bash
python3 -m unittest discover .github/actions/recompute-docker-floating-tags/tests
```

## Example

```yaml
- uses: aerospike/shared-workflows/.github/actions/recompute-docker-floating-tags@<sha> # vX.Y.Z
  with:
    docker-repo: connect-docker-stage-local
    tag: 3.3.2
    floating-tags: aerospike-graph-service:dev
```
