# Setup Discovery Topology

GitHub Action that builds the L2 discovery topology used by pluggable-discovery tests: one endpoint hostname, a port per Aerospike node, and a client that has **no route** to the node IPs.

Call [`setup-aerospike-server`](../setup-aerospike-server) first, with `publish-ports: "false"`. This action then:

1. Creates a client-side Docker network
2. Starts [Toxiproxy](https://github.com/Shopify/toxiproxy) attached to both that network and the Aerospike network
3. Renders a listen-port map from `setup-aerospike-server`'s `container-names` output (`listen-port-base + N - 1` -> `node:upstream-port`)
4. Starts the client container attached **only** to the client network, with the Toxiproxy control API reachable as `http://toxiproxy:8474`

Toxiproxy is used instead of nginx-stream so tests can inject `reset_peer` (TCP RST) through the HTTP control API without rebuilding the proxy.

## Prerequisites

- `setup-aerospike-server` has already started the cluster
- The client image provides `/bin/sh`

## Quick Start

```yaml
- uses: aerospike/shared-workflows/.github/actions/setup-aerospike-server@v3
  id: aerospike
  with:
    num-nodes: "3"
    publish-ports: "false"
    features-content: ${{ secrets.AES_FEATURES_CONF }}
    oidc-provider: ${{ vars.JFROG_OIDC_PROVIDER }}
    oidc-audience: ${{ vars.JFROG_OIDC_AUDIENCE }}

- uses: aerospike/shared-workflows/.github/actions/setup-discovery-topology@v3
  id: topology
  with:
    container-names: ${{ steps.aerospike.outputs.container-names }}
    aerospike-network-name: ${{ steps.aerospike.outputs.network-name }}
    client-image: maven:3-eclipse-temurin-21
    client-volumes: ${{ github.workspace }}:${{ github.workspace }}
    client-workdir: ${{ github.workspace }}
    client-command: >
      mvn -pl test test -Dargs="--endpoint-hostname $DISCOVERY_ENDPOINT_HOSTNAME
      --endpoint-port-base $DISCOVERY_ENDPOINT_PORT_BASE"
```

The `$DISCOVERY_*` and `$TOXIPROXY_*` references are expanded inside the client container, not by GitHub Actions.

## Topology

```text
client network (discovery-client-net)
  discovery-client  -----------------+
  as-endpoint.test:30001 -> node-1   |
  as-endpoint.test:30002 -> node-2   |  Toxiproxy (also on aerospike-net)
  as-endpoint.test:30003 -> node-3   |
  toxiproxy:8474 (control API)  -----+

aerospike-net
  aerospike-1:3000
  aerospike-2:3000
  aerospike-3:3000
```

The client container is not attached to `aerospike-net`, so `aerospike-1` does not resolve and node IPs are unroutable. A translator bug is a connection failure, not a silently passing test.

Fault injection (F-1 `reset_peer`, disable a node, and so on) is done from inside the client against `TOXIPROXY_URL`. Example:

```sh
wget -q -O- --post-data='{"name":"rst","type":"reset_peer","stream":"downstream","attributes":{"timeout":0}}' \
  --header='Content-Type: application/json' \
  "$TOXIPROXY_URL/proxies/aerospike-1/toxics"
```

## Inputs

Required inputs first.

| Input                    | Required | Default                            | Description                                                            |
| ------------------------ | -------- | ---------------------------------- | ---------------------------------------------------------------------- |
| `aerospike-network-name` | Yes      |                                    | Docker network created by `setup-aerospike-server`                     |
| `client-command`         | Yes      |                                    | Shell command run as `sh -c` in the client container                   |
| `client-image`           | Yes      |                                    | Client container image                                                 |
| `container-names`        | Yes      |                                    | Comma-separated Aerospike container names                              |
| `client-container-name`  | No       | `discovery-client`                 | Client container name                                                  |
| `client-env-vars`        | No       |                                    | Semicolon-delimited `KEY=VALUE` pairs. Use `\;` for literal semicolons |
| `client-network-name`    | No       | `discovery-client-net`             | Client-side Docker network name                                        |
| `client-volumes`         | No       | `$GITHUB_WORKSPACE` onto itself    | Semicolon-delimited `host:container[:mode]` mounts                     |
| `client-workdir`         | No       | `$GITHUB_WORKSPACE` if set         | Working directory inside the client container                          |
| `enable-bash-trace-mode` | No       | `false`                            | Print shell commands as they run                                       |
| `endpoint-hostname`      | No       | `as-endpoint.test`                 | Single endpoint hostname (Docker network alias on the client network)  |
| `listen-port-base`       | No       | `30001`                            | First proxy listen port; node N uses `listen-port-base + N - 1`        |
| `proxy-container-name`   | No       | `toxiproxy`                        | Toxiproxy container name and control-API hostname                      |
| `startup-timeout`        | No       | `30`                               | Seconds to wait for the Toxiproxy control API                          |
| `tls-listen-port-base`   | No       |                                    | First TLS proxy listen port; empty skips TLS proxies                   |
| `tls-upstream-port`      | No       | `4333`                             | Aerospike TLS port inside each server container                        |
| `toxiproxy-control-port` | No       | `8474`                             | Toxiproxy HTTP control API port                                        |
| `toxiproxy-image`        | No       | `ghcr.io/shopify/toxiproxy:2.12.0` | Toxiproxy image                                                        |
| `upstream-port`          | No       | `3000`                             | Aerospike service port inside each server container                    |

## Outputs

| Output                     | Description                                                                 |
| -------------------------- | --------------------------------------------------------------------------- |
| `client-container-name`    | Client container name                                                       |
| `client-network-name`      | Client-side Docker network name                                             |
| `endpoint-hostname`        | Endpoint hostname the client should connect to                              |
| `endpoint-port-base`       | First proxy listen port                                                     |
| `endpoint-ports`           | Comma-separated proxy listen ports                                          |
| `proxy-map-json`           | Toxiproxy `/populate` payload                                               |
| `proxy-name-port-map`      | Comma-separated `node:listen-port` map                                      |
| `tls-endpoint-ports`       | Comma-separated TLS proxy listen ports (empty when TLS proxies are skipped) |
| `toxiproxy-container-name` | Toxiproxy container name                                                    |
| `toxiproxy-url`            | Control API URL as reachable from the client (`http://toxiproxy:8474`)      |

## Environment injected into the client

| Variable                       | Example                                   |
| ------------------------------ | ----------------------------------------- |
| `DISCOVERY_ENDPOINT_HOSTNAME`  | `as-endpoint.test`                        |
| `DISCOVERY_ENDPOINT_PORT_BASE` | `30001`                                   |
| `DISCOVERY_ENDPOINT_PORTS`     | `30001,30002,30003`                       |
| `DISCOVERY_TLS_ENDPOINT_PORTS` | `43331,43332,43333` or empty              |
| `DISCOVERY_PROXY_MAP`          | `aerospike-1:30001,aerospike-2:30002,...` |
| `TOXIPROXY_URL`                | `http://toxiproxy:8474`                   |
| `TOXIPROXY_HOST`               | `toxiproxy`                               |
| `TOXIPROXY_CONTROL_PORT`       | `8474`                                    |
| `AEROSPIKE_CONTAINER_NAMES`    | `aerospike-1,aerospike-2,aerospike-3`     |

## TLS pass-through

Set `tls-listen-port-base` to also proxy each node's TLS port. Toxiproxy forwards raw TCP; the Aerospike node still terminates TLS. Proxy names for the TLS listeners are `{container}-tls`.

## Running Tests

```bash
bats .github/actions/setup-discovery-topology/tests/
```
