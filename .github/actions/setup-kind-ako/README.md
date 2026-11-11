# Setup kind and AKO

GitHub Action that builds the L3 discovery cluster: a kind cluster, the Aerospike Kubernetes Operator (AKO) version you choose, an `AerospikeCluster` with `configuredIP` or `networkLoadBalancer` alternate access and one or many pods per node, ingress-nginx TCP services, and the CoreDNS entry that lets the server resolve the shared endpoint hostname.

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

By default the kind cluster is one control-plane node with the control-plane taint removed, so every pod lands on the one node the runner dials. The Aerospike cluster starts at one server. Testing Strategy §7 budgets L3 at 3–5 minutes including kind spin-up, and the scale tests grow the cluster after this action returns. Raise `cluster-size` when a caller needs the extra pods up front. Each added pod gets the next ingress port (`9001`, `9002`, …).

## Inputs

| Input                   | Default                                                     | Description                                                                                                                                         |
| ----------------------- | ----------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------- |
| `features-content`      | required                                                    | Enterprise feature-key file contents                                                                                                                |
| `admin-password`        | generated                                                   | Aerospike admin password                                                                                                                            |
| `ako-version`           | `latest`                                                    | `aerospike-kubernetes-operator` chart version. `latest` is the newest release in `ako-helm-repo`; a prerelease such as `4.8.0-dev1` only when named |
| `ako-helm-repo`         | `https://aerospike.github.io/aerospike-kubernetes-operator` | Helm repository for the AKO and `aerospike-cluster` charts. It carries every 4.x release and the dev builds                                         |
| `cluster-chart-version` | the resolved `ako-version`                                  | `aerospike-cluster` chart version that renders the `AerospikeCluster`. Set it for a dev build, which ships no matching cluster chart                |
| `kind-node-image`       | `kindest/node:v1.35.0`                                      | kind node image. Pick a Kubernetes version the `ako-version` supports                                                                               |
| `alternate-access`      | `configuredIP`                                              | `configuredIP` or `networkLoadBalancer`. See [Alternate access](#alternate-access)                                                                  |
| `multi-pod-per-host`    | `true`                                                      | `false` runs one pod per kind node. Needs `networkLoadBalancer`                                                                                     |
| `cluster-size`          | `1`                                                         | Initial Aerospike servers. Maximum 8                                                                                                                |
| `enable-tls`            | `false`                                                     | Also serve TLS. See [TLS](#tls)                                                                                                                     |
| `server-image`          | `aerospike/aerospike-server-enterprise:8.1.2.5`             | Server image, `repository:tag`                                                                                                                      |

The action resolves `latest` to a concrete chart version once, after `helm repo update`, and prints `AKO chart version: <version>` in the install log, so every run records which AKO it tested. A version containing `-dev` installs with `operatorImage.pullPolicy=Always`, because dev tags are rebuilt in place. To get the cluster earlier releases of this action built, pass `ako-version: 4.5.0` and `ako-helm-repo: https://aerospike.github.io/aerospike-kubernetes-enterprise`.

Callers pin this action by SHA, so the `latest` default and the operator repository reach a caller only when it bumps its pin. A caller that bumps and wants to stay on a known AKO should set `ako-version`.

Everything else is pinned in the action: kind `v0.33.0` and kubectl `v1.35.0` through `helm/kind-action`, helm `v3.22.1` through `azure/setup-helm`, and the cert-manager and ingress-nginx chart versions, repositories, names, and namespaces at the top of `entrypoint.sh`. The AerospikeCluster is rendered by AKO's `aerospike-cluster` chart; its values and the ingress-nginx values are in `templates/`. The kind cluster is `kind-ako`, the AerospikeCluster is `aerospike/aerocluster`, and the action waits up to 300 seconds for it to reach `Completed`. ingress-nginx `4.15.1` is the final release of that project, archived in March 2026; it still supports Kubernetes 1.35. The cluster is not deleted when the job ends.

## Outputs

| Output               | Description                                            |
| -------------------- | ------------------------------------------------------ |
| `admin-password`     | Aerospike admin password                               |
| `alternate-access`   | `alternateAccess` the cluster was built with           |
| `endpoint-hostname`  | Shared alternate-access hostname, `as-endpoint.test`   |
| `ingress-ports`      | tcp-services host ports, comma-separated               |
| `kubeconfig`         | kubeconfig written by kind                             |
| `service-node-ports` | NodePorts for the Aerospike service port, in pod order |
| `tls-ca-file`        | CA certificate file, when `enable-tls` is `true`       |
| `tls-name`           | `aerospike-tls`, when `enable-tls` is `true`           |

`tcp-services` maps ports 9000-9007 to pods 0-7 up front, so pods added by scaling after this action returns are reachable without updating it.

## Alternate access

With `alternate-access: configuredIP`, the action labels every node `aerospike.com/configured-alternate-access-address=as-endpoint.test` and AKO advertises that label value with each pod's Service NodePort, as in the topology above.

With `alternate-access: networkLoadBalancer`, the action labels no node. It sets `alternateAccess: networkLoadBalancer` and `loadBalancerAlternateAccessAddress: as-endpoint.test` in the `AerospikeCluster`, and with `enable-tls: true` also `tlsAlternateAccess: networkLoadBalancer` and `loadBalancerTLSAlternateAccessAddress: as-endpoint.test`. AKO gives every pod its own NodePort Service and sets no `hostPort`. Right after installing AKO the action reads the `alternateAccess` enum in the installed `AerospikeCluster` CRD and fails before applying the cluster if it does not list `networkLoadBalancer`. Released AKO up to 4.7.0 does not list it; use an `ako-version` that does, such as `4.8.0-dev1` with `cluster-chart-version: 4.7.0`.

With `multi-pod-per-host: false` the `AerospikeCluster` sets `multiPodPerHost: false` and the kind cluster has one control-plane node and `cluster-size + 1` workers, so a caller can scale up by one or reschedule a pod. The CoreDNS entry and `/etc/hosts` still point the endpoint hostname at the first node's InternalIP, the way an NLB address fronts every node. AKO creates each pod Service with `externalTrafficPolicy: Local`, which answers only on the pod's own node, so once the cluster is up the action patches those Services to `Cluster` and pins the ingress-nginx controller to that first node. A pod added by scaling after the action returns gets a new `Local` Service; patch it the same way before dialing its NodePort through the endpoint hostname. `configuredIP` is rejected with `multi-pod-per-host: false`.

## TLS

With `enable-tls: true`, the action generates a CA and a server certificate whose only SAN is the dNSName `aerospike-tls`, adds them to `aerospike-secret` with the server key, and layers `templates/aerospike-cluster-tls-values.yaml` over the cluster values. Every pod serves TLS on `tls-port` 4333 with that tls-name, and `tlsAlternateAccess` matches `alternateAccess`, so each pod advertises the endpoint hostname with its own Service NodePort for 4333. The certificate does not name the endpoint hostname, so a client must validate each node against the tls-name the cluster advertises. The CA key and the server key file are deleted once the secret holds them. Client certificates are not required.

## Tests

```sh
bats .github/actions/setup-kind-ako/tests/
```

`example_setup-kind-ako.yaml` runs the action on `workflow_dispatch`. It needs the `AES_FEATURES_CONF` secret.
