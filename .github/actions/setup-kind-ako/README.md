# Setup kind and AKO

GitHub Action that builds the L3 discovery cluster: one kind node, the Aerospike Kubernetes Operator, an `AerospikeCluster`, ingress-nginx TCP services, and the CoreDNS entry that lets the server resolve the shared endpoint hostname.

The client process runs on the runner. kind publishes the ports it dials to `127.0.0.1`, and the action adds that hostname to the runner's `/etc/hosts`.

## What it guarantees

The API server NodePort range is pinned to **30000-32767**, the Kubernetes default. That is the range KEP-3668 splits into an 86-port static band and a dynamic band, which is the same split a GKE cluster gets. kind will widen the range through `kubeadmConfigPatches`. The **Assert NodePort range is 30000-32767** step reads the flag back from the API server process and rejects Service `nodePort` values outside that range, so a later edit that opens the range fails the job.

`client-ports` only controls which of those ports are published on the runner. It does not change the range the API server serves. The default publishes `30000-32767`, so a test can dial whatever NodePort the operator assigns. Narrow it when a run only needs a known set of ports; publishing the full range makes `kind create` slower.

## Quick Start

```yaml
- uses: aerospike/shared-workflows/.github/actions/setup-kind-ako@<sha> # vX.Y.Z
  id: kind-ako
  with:
    features-content: ${{ secrets.AEROSPIKE_FEATURE_KEY }}

- run: |
    echo "seed ${{ steps.kind-ako.outputs.endpoint-hostname }}:${{ steps.kind-ako.outputs.service-node-ports }}"
```

`features-file` is the other way to pass the Enterprise feature key. One of the two is required.

## Topology

```text
runner (client JVM)
  /etc/hosts: as-endpoint.test -> 127.0.0.1
  127.0.0.1:9000  -> ingress tcp-services -> aerocluster-0-0:3000
  127.0.0.1:9001  -> ingress tcp-services -> aerocluster-0-1:3000
  127.0.0.1:<nodePort> -> kind extraPortMappings -> Service nodePort

kind node
  CoreDNS: as-endpoint.test -> node InternalIP
  node label aerospike.com/configured-alternate-access-address=as-endpoint.test
  AerospikeCluster alternateAccess: configuredIP, multiPodPerHost: true
```

Inside the cluster the hostname resolves to the node IP, which is enough for the server to start. AKO writes a DNS name into `alternate-access-address` from that label; that path is unsupported and works because nothing rejects it yet. On the runner the same name resolves to `127.0.0.1`, where the published ports are listening.

The cluster is one control-plane node with the control-plane taint removed, so every pod lands on the node whose ports are published.

## Inputs

| Input                         | Default                                                       | Description                                                           |
| ----------------------------- | ------------------------------------------------------------- | --------------------------------------------------------------------- |
| `admin-password`              | generated                                                     | Aerospike admin password                                              |
| `ako-chart-version`           | `4.5.0`                                                       | AKO Helm chart version                                                |
| `ako-helm-repo`               | `https://aerospike.github.io/aerospike-kubernetes-enterprise` | AKO chart repository                                                  |
| `ako-namespace`               | `ako`                                                         | Namespace the operator is installed into                              |
| `cert-manager-chart-version`  | `v1.17.0`                                                     | cert-manager chart version                                            |
| `cert-manager-helm-repo`      | `https://charts.jetstack.io`                                  | cert-manager chart repository                                         |
| `client-ports`                | `30000-32767`                                                 | Ports published to `127.0.0.1`. `N` or `N-M`, comma-separated         |
| `cluster-name`                | `aerocluster`                                                 | AerospikeCluster name                                                 |
| `cluster-namespace`           | `aerospike`                                                   | AerospikeCluster namespace                                            |
| `cluster-size`                | `2`                                                           | Pods in the initial cluster. Maximum 8                                |
| `enable-bash-trace-mode`      | `false`                                                       | Print shell commands as they run                                      |
| `endpoint-hostname`           | `as-endpoint.test`                                            | Shared alternate-access hostname                                      |
| `features-content`            |                                                               | Feature-key file contents. Ignored when `features-file` is set        |
| `features-file`               |                                                               | Path to a feature-key file on the runner                              |
| `helm-version`                | `v3.18.4`                                                     | Helm version installed on the runner                                  |
| `ingress-namespace`           | `ingress-nginx`                                               | ingress-nginx namespace                                               |
| `ingress-nginx-chart-version` | `4.12.1`                                                      | ingress-nginx chart version                                           |
| `ingress-nginx-helm-repo`     | `https://kubernetes.github.io/ingress-nginx`                  | ingress-nginx chart repository                                        |
| `ingress-port-base`           | `9000`                                                        | First tcp-services host port. One port per pod, outside `30000-32767` |
| `kind-cluster-name`           | `kind-ako`                                                    | kind cluster name                                                     |
| `kind-node-image`             | `kindest/node:v1.35.0`                                        | kind node image. AKO 4.5.0 supports Kubernetes through 1.35           |
| `kind-version`                | `v0.33.0`                                                     | kind version installed on the runner                                  |
| `kubectl-version`             | `v1.35.0`                                                     | kubectl version installed on the runner                               |
| `server-image`                | `aerospike/aerospike-server-enterprise:8.1.2.5`               | Server image on the AerospikeCluster                                  |
| `startup-timeout`             | `600`                                                         | Seconds to wait for the cluster phase `Completed`                     |

## Outputs

| Output               | Description                                              |
| -------------------- | -------------------------------------------------------- |
| `admin-password`     | Aerospike admin password                                 |
| `cluster-name`       | AerospikeCluster name                                    |
| `cluster-namespace`  | AerospikeCluster namespace                               |
| `endpoint-address`   | `127.0.0.1`                                              |
| `endpoint-hostname`  | Shared alternate-access hostname                         |
| `ingress-endpoints`  | `hostname:port` pairs for the tcp-services host ports    |
| `ingress-ports`      | tcp-services host ports                                  |
| `kind-cluster-name`  | kind cluster name                                        |
| `kubeconfig`         | kubeconfig written by kind                               |
| `node-port-range`    | `30000-32767` after the API server check                 |
| `service-endpoints`  | `hostname:nodePort` pairs for the Aerospike service port |
| `service-node-ports` | NodePorts for the Aerospike service port, in pod order   |

Scaling the cluster after this action returns does not update the `tcp-services` ConfigMap.

## Tests

```sh
bats .github/actions/setup-kind-ako/tests/
```

`example_setup-kind-ako.yaml` runs the action on `workflow_dispatch`. It needs the `AEROSPIKE_FEATURE_KEY` secret.
