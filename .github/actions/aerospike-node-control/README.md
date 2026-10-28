# Aerospike Node Control

GitHub Action that starts a background helper which adds and removes nodes of a cluster created by [`setup-aerospike-server`](../setup-aerospike-server) **while a test runs**, for tests that measure how a client reacts to a node joining mid-run, such as a scale-out latency budget.

A composite action cannot run in the middle of another step, so this action only starts the helper and returns. The test step then talks to it through files in `control-dir`. The helper keeps running until the job ends.

Each start runs a new node cloned from a template node: a node `setup-aerospike-server` created with `docker create` but did not start (`start-nodes` below `num-nodes`). The clone gets the template's image, config, mounts, environment and extra hosts, and the next free name `<container-name-prefix>-<N>` after the template. A stop removes a node the helper started, so a test can clean up after itself. Nodes started by `setup-aerospike-server` cannot be stopped here.

## Prerequisites

- `setup-aerospike-server` ran earlier in the same job with `num-nodes` above 1, so every node has its own config file, and `start-nodes` below `num-nodes`, so a template node exists
- Node 1 is running. It mounts the config volume, and the helper copies each new node's config through it

## Usage

```yaml
- uses: aerospike/shared-workflows/.github/actions/setup-aerospike-server@v3
  id: aerospike
  with:
    num-nodes: "4"
    start-nodes: "3"
    network-subnet: 172.30.0.0/24
    features-content: ${{ secrets.AEROSPIKE_SERVER_FEATURES_CONF }}
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}

- uses: aerospike/shared-workflows/.github/actions/aerospike-node-control@v3
  id: node-control
  with:
    cluster-settings: ${{ steps.aerospike.outputs.cluster-settings }}
    template-node-index: "4"

- name: Run tests
  env:
    NODE_CONTROL_DIR: ${{ steps.node-control.outputs.control-dir }}
  run: ./run-tests.sh
```

A test in a container needs `control-dir` bind-mounted at the same path.

## Requests

The test writes one request per file and waits for the matching acknowledgement:

1. Write the request line to `<id>.tmp` in `control-dir`, then rename it to `<id>.request`. The rename makes the request appear whole. `<id>` is any unique name, such as a UUID.
2. Wait for `<id>.ack`. It is renamed into place too, so once it exists it is complete. It holds one `key=value` per line.

| Request                       | Success acknowledgement                    |
| ----------------------------- | ------------------------------------------ |
| `start`                       | `container=<name>` and `address=<ip>`      |
| `start address=<ip>`          | The same, with the node on that IP         |
| `start alternate-port=<port>` | The same, with an alternate access address |
| `stop <name>`                 | `removed=<name>`                           |

A failed request is acknowledged with one `error=<message>` line, and the helper keeps serving.

- `address=<ip>` starts the node on that IP, which must be free and inside the network's subnet. Use it with `network-subnet` to place a node on a known address. Without it, Docker picks a free IP, which can be the template's fixed IP, because a node that never started does not hold one.
- `alternate-port=<port>` adds `alternate-access-address <alternate-access-address>` and `alternate-access-port <port>` after the `port <service-port>` line of the new node's config. It needs the `alternate-access-address` input.
- Options combine, as in `start address=172.30.0.20 alternate-port=30005`.

The helper does not wait for the cluster. A start is acknowledged once the container runs, and a stop once it is removed, so the test waits for the cluster size or for its client to see the node.

A config that derives `node-id` from `{{NODE_INDEX}}` gives every clone the template's node ID. The generated configs set none.

## Inputs

| Input                      | Required | Default                               | Description                                                                                   |
| -------------------------- | -------- | ------------------------------------- | --------------------------------------------------------------------------------------------- |
| `cluster-settings`         | Yes      |                                       | The `cluster-settings` output of `setup-aerospike-server`                                     |
| `template-node-index`      | Yes      |                                       | 1-based index of a node `setup-aerospike-server` created but did not start                    |
| `control-dir`              | No       | `$RUNNER_TEMP/aerospike-node-control` | Directory the test writes requests to                                                         |
| `alternate-access-address` | No       |                                       | Hostname or IP that `alternate-port=<port>` writes as the new node's alternate access address |
| `enable-bash-trace-mode`   | No       | `false`                               | Show commands being executed in shell scripts for debugging                                   |

## Outputs

| Output        | Description                               |
| ------------- | ----------------------------------------- |
| `control-dir` | Directory the helper serves requests from |
| `log-file`    | The helper's log on the runner            |

With strong consistency, a node started here is not added to the roster that `setup-aerospike-server` set.
