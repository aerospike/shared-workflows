# Setup kind and AKO

GitHub Action that builds the L3 discovery cluster: one kind node, the Aerospike Kubernetes Operator, an `AerospikeCluster`, ingress-nginx TCP services, and the CoreDNS entry that lets the server resolve the shared endpoint hostname.

The client process runs on the runner and dials the kind node's IP directly. The action points the endpoint hostname at that IP in the runner's `/etc/hosts`.

Nothing is published to `127.0.0.1`. On a Linux runner the kind node's Docker network is reachable from the host, so a test can dial whatever NodePort the operator assigns at the node IP. Publishing every NodePort made `kind create` take about 7 minutes.

## Quick Start

```yaml
- uses: aerospike/shared-workflows/.github/actions/setup-kind-ako@<sha> # vX.Y.Z
  id: kind-ako
  with:
    features-content: ${{ secrets.AEROSPIKE_FEATURE_KEY }}

- run: |
    echo "seed ${{ steps.kind-ako.outputs.endpoint-hostname }}:${{ steps.kind-ako.outputs.service-node-ports }}"
```

## Topology

```text
runner (client JVM)
  /etc/hosts: as-endpoint.test -> node InternalIP
  <node IP>:9000       -> ingress tcp-services -> aerocluster-0-0:3000
  <node IP>:<nodePort> -> Service nodePort

kind node
  CoreDNS: as-endpoint.test -> node InternalIP
  node label aerospike.com/configured-alternate-access-address=as-endpoint.test
  AerospikeCluster size 1, alternateAccess: configuredIP, multiPodPerHost: true
```

Inside the cluster the hostname resolves to the node IP, which is enough for the server to start. AKO writes a DNS name into `alternate-access-address` from that label; that path is unsupported and works because nothing rejects it yet. On the runner the same name resolves to the same node IP.

The kind cluster is one control-plane node with the control-plane taint removed, so every pod lands on the one node the runner dials. The Aerospike cluster starts at one server. Testing Strategy §7 budgets L3 at 3–5 minutes including kind spin-up, and the scale tests grow the cluster after this action returns. Raise `cluster-size` when a caller needs the extra pods up front. Each added pod gets the next ingress port (`9001`, `9002`, …).

## Inputs

| Input              | Default                                         | Description                          |
| ------------------ | ----------------------------------------------- | ------------------------------------ |
| `features-content` | required                                        | Enterprise feature-key file contents |
| `admin-password`   | generated                                       | Aerospike admin password             |
| `cluster-size`     | `1`                                             | Initial Aerospike servers. Maximum 8 |
| `server-image`     | `aerospike/aerospike-server-enterprise:8.1.2.5` | Server image on the AerospikeCluster |

Everything else is pinned in the action: kind `v0.33.0` and kubectl `v1.35.0` through `helm/kind-action`, the node image `kindest/node:v1.35.0`, helm `v3.22.1` through `azure/setup-helm`, and the chart versions, repositories, names, and namespaces at the top of `entrypoint.sh`. The manifests and ingress-nginx values are in `templates/`. The kind cluster is `kind-ako`, the AerospikeCluster is `aerospike/aerocluster`, and the action waits up to 300 seconds for it to reach `Completed`. ingress-nginx `4.15.1` is the final release of that project, archived in March 2026; it still supports Kubernetes 1.35. The cluster is not deleted when the job ends.

## Outputs

| Output               | Description                                            |
| -------------------- | ------------------------------------------------------ |
| `admin-password`     | Aerospike admin password                               |
| `endpoint-hostname`  | Shared alternate-access hostname, `as-endpoint.test`   |
| `ingress-ports`      | tcp-services host ports, comma-separated               |
| `kubeconfig`         | kubeconfig written by kind                             |
| `service-node-ports` | NodePorts for the Aerospike service port, in pod order |

Scaling the cluster after this action returns does not update the `tcp-services` ConfigMap.

## Tests

```sh
bats .github/actions/setup-kind-ako/tests/
```

`example_setup-kind-ako.yaml` runs the action on `workflow_dispatch`. It needs the `AES_FEATURES_CONF` secret.
