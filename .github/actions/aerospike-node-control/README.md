# Aerospike Node Control

GitHub Action that starts or stops one node of a cluster created by [`setup-aerospike-server`](../setup-aerospike-server), for tests of node join, scale-out and failover.

After `docker start` or `docker stop` on `<container-name-prefix>-<node-index>`, the action counts the running nodes and waits until each of them reports a stable cluster of that size (`asinfo -v cluster-stable:size=N`). After `start`, the node has joined; after `stop`, the remaining nodes have dropped it. It fails if the node is already in the requested state or does not exist.

## Prerequisites

- `setup-aerospike-server` ran earlier in the same job. Nodes it did not start (`start-nodes` below `num-nodes`) can be started here, and stopped nodes can be started again
- The Docker login from `setup-aerospike-server` is still valid, since the wait pulls the tools image

## Usage

```yaml
- uses: aerospike/shared-workflows/.github/actions/setup-aerospike-server@v3
  id: aerospike
  with:
    num-nodes: "3"
    start-nodes: "2"
    features-content: ${{ secrets.AEROSPIKE_SERVER_FEATURES_CONF }}
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}

- uses: aerospike/shared-workflows/.github/actions/aerospike-node-control@v3
  id: start-node-3
  with:
    cluster-settings: ${{ steps.aerospike.outputs.cluster-settings }}
    node-index: "3"
    operation: start

- run: echo "cluster size ${{ steps.start-node-3.outputs.cluster-size }}" # 3

- uses: aerospike/shared-workflows/.github/actions/aerospike-node-control@v3
  with:
    cluster-settings: ${{ steps.aerospike.outputs.cluster-settings }}
    node-index: "2"
    operation: stop
```

`cluster-settings` carries the container name prefix, network, service port, security, strong consistency and tools image that `setup-aerospike-server` used, so they are never passed twice.

## Inputs

| Input                    | Required | Default | Description                                                                  |
| ------------------------ | -------- | ------- | ---------------------------------------------------------------------------- |
| `cluster-settings`       | Yes      |         | The `cluster-settings` output of `setup-aerospike-server`                    |
| `node-index`             | Yes      |         | 1-based index of the node (container `<container-name-prefix>-<node-index>`) |
| `operation`              | Yes      |         | `start` or `stop`                                                            |
| `timeout`                | No       | `30`    | Seconds to wait for each running node to report a stable cluster             |
| `enable-bash-trace-mode` | No       | `false` | Show commands being executed in shell scripts for debugging                  |

## Outputs

| Output          | Description                                                                    |
| --------------- | ------------------------------------------------------------------------------ |
| `cluster-size`  | Number of running nodes, which every running node reported as the cluster size |
| `running-nodes` | Comma-separated names of the running nodes                                     |
| `node-address`  | IP of the node on `network-name`; may be empty after `stop`                    |

With strong consistency, a node started here is not added to the roster that `setup-aerospike-server` set.
