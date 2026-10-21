# Aerospike Node Control

GitHub Action that starts or stops one node of a cluster created by [`setup-aerospike-server`](../setup-aerospike-server), for tests of node join, scale-out and failover.

After `docker start` or `docker stop` on `<container-name-prefix>-<node-index>`, the action counts the running nodes and waits until each of them reports a stable cluster of that size (`asinfo -v cluster-stable:size=N`). After `start`, the node has joined; after `stop`, the remaining nodes have dropped it. It fails if the node is already in the requested state or does not exist.

## Prerequisites

- `setup-aerospike-server` ran earlier in the same job. Nodes it did not start (`start-nodes` below `num-nodes`) can be started here, and stopped nodes can be started again
- The Docker login from `setup-aerospike-server` is still valid, since the wait pulls the tools image

## Usage

```yaml
- uses: aerospike/shared-workflows/.github/actions/setup-aerospike-server@v3
  with:
    num-nodes: "3"
    start-nodes: "2"
    features-content: ${{ secrets.AEROSPIKE_SERVER_FEATURES_CONF }}
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}

- uses: aerospike/shared-workflows/.github/actions/aerospike-node-control@v3
  id: start-node-3
  with:
    node-index: "3"
    operation: start

- run: echo "cluster size ${{ steps.start-node-3.outputs.cluster-size }}" # 3

- uses: aerospike/shared-workflows/.github/actions/aerospike-node-control@v3
  with:
    node-index: "2"
    operation: stop
```

Pass the same `container-name-prefix`, `network-name`, `service-port`, `enable-security` and `enable-strong-consistency` values that were passed to `setup-aerospike-server` when they are not the defaults.

## Inputs

| Input                       | Required | Default              | Description                                                                  |
| --------------------------- | -------- | -------------------- | ---------------------------------------------------------------------------- |
| `node-index`                | Yes      |                      | 1-based index of the node (container `<container-name-prefix>-<node-index>`) |
| `operation`                 | Yes      |                      | `start` or `stop`                                                            |
| `container-name-prefix`     | No       | `aerospike`          | Container name prefix passed to `setup-aerospike-server`                     |
| `network-name`              | No       | `aerospike-net`      | Docker network name passed to `setup-aerospike-server`                       |
| `service-port`              | No       | `3000`               | Aerospike service port inside the container                                  |
| `timeout`                   | No       | `30`                 | Seconds to wait for each running node to report a stable cluster             |
| `enable-security`           | No       | `false`              | Authenticate the wait with admin/admin                                       |
| `enable-strong-consistency` | No       | `false`              | Ignore migrations while waiting                                              |
| `container-repo-url`        | No       | `aerospike.jfrog.io` | Docker registry hostname for the tools image                                 |
| `tools-tag`                 | No       | `12.1.1_2`           | Aerospike tools Docker image tag                                             |
| `enable-bash-trace-mode`    | No       | `false`              | Show commands being executed in shell scripts for debugging                  |

## Outputs

| Output          | Description                                                                    |
| --------------- | ------------------------------------------------------------------------------ |
| `cluster-size`  | Number of running nodes, which every running node reported as the cluster size |
| `running-nodes` | Comma-separated names of the running nodes                                     |
| `node-address`  | IP of the node on `network-name`; may be empty after `stop`                    |

With strong consistency, a node started here is not added to the roster that `setup-aerospike-server` set.
