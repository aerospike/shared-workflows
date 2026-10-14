# Recompute Docker floating tags

Point a tag the caller named at this release's mutable version, the timestamp stripped from `version`. With only the project, repository, bundle, and version, nothing is attached. Applying `latest` and `latest-slim` is optional, and both are off by default. Each flag writes that exact name. The repository is not searched for a newer tag. Promotion calls this action only when its matching input is true.

Floating tags belong to the repository, not to one release bundle. Promotion copies the version tags that are in the bundle. There is no un-promote workflow in this repo, and this action does not delete the bundle. `delete-release-bundle` still refuses a bundle that has been promoted beyond DEV.

## What it retags

`floating-tags` is a semicolon-separated list of `image:tag` values the caller typed, for example `aerospike-graph-service:dev`.

`latest` and `latest-slim` are separate inputs. Both default to off. Set `latest: true` to apply `latest`, and `latest-slim: true` to apply `latest-slim`.

The named tag is pointed at this release's mutable version. `3.3.2_20261007T212412Z` is `3.3.2`. A newer tag already in the repository is left where it is. This action does not rewrite `-dev-local` into another suffix.

## Prerequisites

JFrog CLI must be configured before calling this action (via `setup-jfrog-cli`).

## Inputs

| Input           | Required | Description                                                                                            |
| --------------- | -------- | ------------------------------------------------------------------------------------------------------ |
| `jf-project`    | Yes      | JFrog project key                                                                                      |
| `docker-repo`   | Yes      | Stage Docker or OCI repository key to retag                                                            |
| `bundle-name`   | Yes      | Release bundle name                                                                                    |
| `version`       | Yes      | Release bundle version                                                                                 |
| `floating-tags` | No       | `image:tag` list the caller typed, separated by semicolons (for example `aerospike-graph-service:dev`) |
| `latest`        | No       | Apply the `latest` tag. Optional, off by default                                                       |
| `latest-slim`   | No       | Apply the `latest-slim` tag. Optional, off by default                                                  |

## Command

The action runs `recompute.py retag`. The same file can be run directly when JFrog CLI is already configured. `print-property` prints the bundle property, and `repos` reads a promotion result or repository catalog on stdin.

```bash
python3 .github/actions/recompute-docker-floating-tags/recompute.py retag \
  --project connect \
  --repo connect-docker-stage-local \
  --bundle-name aerospike-graph-service-container \
  --version 3.3.2 \
  --floating-tags aerospike-graph-service:dev
```

`--latest` and `--latest-slim` are optional and off unless you pass them.

```bash
python3 -m unittest discover .github/actions/recompute-docker-floating-tags/tests
```

## Example

```yaml
- uses: aerospike/shared-workflows/.github/actions/recompute-docker-floating-tags@<sha> # vX.Y.Z
  with:
    jf-project: connect
    docker-repo: connect-docker-stage-local
    bundle-name: aerospike-graph-service-container
    version: 3.3.2
    floating-tags: aerospike-graph-service:dev
```
